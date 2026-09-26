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
    // *** GS-UX-001 `rendered-controls` / `.accessibility`: THE LAB RENDERETH REAL CONTROLS. ***
    //
    // *THE OBLIGATION'S OWN WORDS: the journey controls must carry `contentDescription`, `stateDescription`,
    // `semanticsRole` and LiveRegion announcements, and a court must assert them through the SEMANTICS TREE rather
    // than by reading source text.* **That requires a compose surface in this module, so the lab gains the SAME
    // Compose stack `:app` carrieth -- never a lab-only twin of it.** *The lab-isolation gate watcheth for readiness
    // overrides and lab source roots reaching LIGHT; a Compose dependency in the LAB is neither.*
    id("org.jetbrains.kotlin.plugin.compose")
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
        // GS-UX-001: the rendered journeys live here, so the lab really composes.
        compose = true
    }

    testOptions {
        unitTests {
            // *The semantics court runneth under Robolectric, which needs the module's resources -- the same
            // `testOptions` block `:app` and `:mesh` already carry.*
            isIncludeAndroidResources = true
        }
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

    // GS-UX-001: the SAME Compose stack `:app` carrieth (one BOM, one version set), so the lab's rendered journeys
    // are the shipping toolkit's rather than a second one's.
    //
    // *** AND THE DEPENDENCY SET IS `:app`'s OWN, VERSION FOR VERSION, WHICH IS A SUPPLY-CHAIN DECISION RATHER THAN
    // A STYLE ONE. *** *MEASURED: a narrower Compose set resolved TRANSITIVE versions (`lifecycle-*:2.8.3`/`2.6.x`,
    // `collection-ktx:1.2.0`, `annotation-jvm:1.8.0`) whose `.module` checksums are NOT in
    // `gradle/verification-metadata.xml` -- 26 artifacts failed verification, then 1, then another.*
    // **THE LAB MUST NOT WIDEN THE PINNED ARTIFACT SET TO RENDER A SCREEN: declaring `:app`'s exact set (and its own
    // explicit lifecycle/annotation pins) resolves the versions the supply chain ALREADY carries, so the pinned set
    // is exactly as wide as it was before this change.***
    implementation(platform("androidx.compose:compose-bom:2024.09.02"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.navigation:navigation-compose:2.8.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.6")
    implementation("androidx.annotation:annotation-jvm:1.8.1")
    implementation("androidx.collection:collection-ktx:1.4.4")
    // *The semantics model the accessibility obligations are asserted against lives in `:mesh`, which this lab
    // already reaches; the contract itself is the shared table, never a copy.*

    testImplementation("junit:junit:4.13.2")
    // the SAME test stack :mesh's own courts use, so the lab adds no new
    // third-party artifact to the pinned supply-chain set
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test:2.0.20")
    // *** THE SEMANTICS COURT'S OWN INSTRUMENTS, IDENTICAL TO `:app`'s. *** *`createComposeRule` really composes,
    // really lays out and really publishes a semantics tree, so the assertions read the RENDERED tree rather than a
    // source declaration -- and Robolectric 4.13 lets it run in the host unit-test task.*
    testImplementation("org.robolectric:robolectric:4.13")
    testImplementation("androidx.test.ext:junit:1.2.1")
    testImplementation(platform("androidx.compose:compose-bom:2024.09.02"))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.6")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
