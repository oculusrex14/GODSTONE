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

    // *** ANDROID-05 (round 589): ANDROID RESOURCES FOR A REAL `Context` IN THIS MODULE'S COURTS. ***
    //
    // THE CARD DEMANDED "a Context-bearing composition harness", AND THE WALL WAS RECORDED AS "no host test can supply
    // a Context". **MEASURED, THAT IS TRUE ONLY OF THE DI ROOT: `MeshModule`'s providers whose signatures literally
    // take `@ApplicationContext ctx` need a real Context, WHILE THE REST ARE ORDINARY CALLABLE FUNCTIONS ON AN
    // `internal object` (round 571 called `provideBoundRecipientKeyResolver` directly and it WORKED).**
    // THE ROUTE TO THE REST IS ALREADY PROVEN ON THIS REPO: the `:app` module carries Robolectric and a test
    // `testOptions` block (round 564), with its artifacts pinned in `gradle/verification-metadata.xml`. **THE SAME
    // MOVE, APPLIED HERE.**
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }

    // *** GS-FINAL-003 `same-estate`: THE HOST PLATFORM IS A SHARED FIXTURE. ***
    //
    // *The host substitution the LAB COURTS need -- real on-disk SQLite behind the AndroidKeyStore/SQLCipher doors
    // alone -- is the SAME machinery the `:mesh` courts already carry (`JdbcStoreDb`, `JdbcPeerIdentityStore`).*
    // **Exposing it as a `testFixtures` source set means `:labmesh` consumes ONE host platform rather than keeping a
    // second copy; AGP 8.5+ publishes that source set to a consuming module only when Kotlin fixtures support is
    // enabled (see `gradle.properties`'s `android.experimental.enableTestFixturesKotlinSupport`).**
    testFixtures {
        enable = true
    }

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
    // GS-FINAL-003 (ii): the DAGGER COMPONENT PROCESSOR, so `@Component` interfaces in this module are actually
    // generated and their graphs VALIDATED at compile time. Hilt's processor alone does not process bare
    // `@Component` -- `HiltWrapper_MeshModule` made the module includable, but nothing assembled it until now.
    ksp("com.google.dagger:dagger-compiler:2.52")

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
    // THE CONTEXT-BEARING HARNESS'S OWN INSTRUMENTS -- the same pair the `:app` isle carries (round 564), so a court
    // here can obtain a REAL Android `Context` on the host. Test-only; never reaches a shipping classpath.
    testImplementation("org.robolectric:robolectric:4.13")
    testImplementation("androidx.test.ext:junit:1.2.1")

    // *** THE HOST FIXTURE'S OWN CLASSPATH: real on-disk SQLite, exposed to CONSUMING modules' tests. ***
    // *`JdbcStoreDb`/`JdbcPeerIdentityStore` live in `src/testFixtures` and are compiled against `org.xerial:sqlite-jdbc`,
    // which a consumer's test classpath must therefore carry.* **`testFixturesApi` exports it transitively (the fixture's
    // own public surface names `java.io.File`, but the JDBC driver is loaded by reflection at runtime, so `api` rather
    // than `implementation` keeps a consumer's host court working without a second declaration).** *The artifact is the
    // SAME pinned one the module's own tests already use -- no new supply-chain entry.*
    testFixturesApi("org.xerial:sqlite-jdbc:3.46.1.3")
    // *The fixture's `HostLabPlatform` also names `:core`'s `Ed25519Keys`/`X25519Keys`, so the fixture compile
    // classpath carrieth the SAME `:core` the main variant uses -- never a second declaration.*
    testFixturesImplementation(project(":core"))
}

// =====================================================================================================================
// *** GS-INTEGRATION-001 `real-adapters`: THE EXPLICIT `board1IntegrationWorker` TASK. ***
//
// THE PLAN'S OWN WORDS: "the Kotlin worker reuseth the `:mesh` test classpath/Robolectric setup through a dedicated
// `board1IntegrationWorker` Gradle task. Worker launch is EXPLICIT, not a default-suite empty/skipped test."
//
// *A `Test` task DERIVED from the debug unit-test variant, so it CARRIETH the variant's own classes/classpath (the
// Robolectric + sqlite-jdbc + junit test classpath) rather than a hand-assembled one.* **`outputs.upToDateWhen {
// false }` is mandatory: an up-to-date worker would report a stale green.** JUnit XML is on by default for a `Test`
// task and is stated explicitly here, so the coordinator has a stable artifact path.
//
// THE FILTER NAMES THE RIG'S OWN CLASSES (`RealTransportHostRig`, `RealTransportHostRigTests`, and the cross-process
// `RealTransportHostRigWorkerTest` owned by the coordinator), so this task RUNNETH the rig court rather than an empty
// selection. Launch it explicitly:
//
//   cd android && ./gradlew :mesh:board1IntegrationWorker --no-daemon
//
// The rig court also participateth in the ordinary `:mesh:testDebugUnitTest` run (it is a normal test class), so no
// arm of it is silently excluded from the default suite.
// =====================================================================================================================

tasks.register<Test>("board1IntegrationWorker") {
    group = "verification"
    description = "GS-INTEGRATION-001 real-adapters: runs the Android real-transport host rig court and the " +
        "cross-process integration worker explicitly (not a default-suite empty/skipped test)."

    // *THE DEBUG UNIT-TEST TASK'S OWN CLASSES AND CLASSPATH, carried straight from it* -- so this worker runneth on
    // the SAME Robolectric/sqlite-jdbc/junit runtime classpath the default suite useth, with no hand-assembled
    // classpath to drift. `tasks.named` keepeth this configuration-cache-safe (no other task is RESOLVED at
    // configuration time).
    val debugUnitTest = tasks.named<Test>("testDebugUnitTest")
    testClassesDirs = debugUnitTest.get().testClassesDirs
    classpath = debugUnitTest.get().classpath
    filter { includeTestsMatching("*RealTransportHostRig*") }

    // An up-to-date worker is a stale green: always re-run, and retain the XML the coordinator consumes.
    outputs.upToDateWhen { false }
    reports.junitXml.required.set(true)
    reports.junitXml.outputLocation.set(layout.buildDirectory.dir("test-results/board1IntegrationWorker"))
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = true
    }
    // The coordinator's own parameter names, forwarded to the worker JVM through the configuration-cache-correct
    // provider API (never a configuration-time `System.getProperties()` read).
    listOf("role", "root", "in", "out", "mode", "metadata", "variant", "deadlineSeconds").forEach { key ->
        val name = "godstone.integration.$key"
        systemProperty(name, providers.systemProperty(name).getOrElse(""))
    }
}

// =====================================================================================================================
// *** GS-INTEGRATION-001 `scenarios` (step 6): THE ANDROID DURABLE-BOUNDARY WORKER -- APPENDED, NOT SUBSTITUTED. ***
//
// THE PLAN'S OWN WORDS: "Mirror the durable-boundary recovery assertions against Android's real host store/runtime
// path using fresh Robolectric worker JVMs controlled by the same host coordinator. Do not kill a Gradle daemon or
// unrelated test process; target the registered worker only."
//
// *`board1IntegrationWorker` ABOVE BELONGETH TO THE CROSS-PLATFORM ISLE AND IS DELIBERATELY UNTOUCHED: this task is a
// SECOND, SEPARATE registration that selecteth only `Board1DurableBoundaryWorkerTest`, so the crash mirror can be
// launched (and re-launched by the parent campaign for its child roles) without ever re-running, or reaching into,
// the cross-platform court.* **Its `outputs.upToDateWhen { false }` is mandatory for the same reason: an up-to-date
// worker would report a stale green -- and here it would be worse than stale, because a worker role that is never
// re-executed cannot reach its boundary at all.**
//
//   cd android && ./gradlew :mesh:board1DurableBoundaryWorker --no-daemon
//
// and the coordinator's crash arm reacheth it through its own env hooks:
//
//   GS_ANDROID_CRASH_TASK=:mesh:board1DurableBoundaryWorker \
//   GS_ANDROID_CRASH_CLASS=io.godstone.mesh.rig.Board1DurableBoundaryWorkerTest \
//   python3 tools/readiness/run_board1_integration.py --mode crash --evidence-dir <path>
//
// and the acceptance court runneth it through the ordinary debug unit-test task by name:
//
//   ./gradlew :mesh:testDebugUnitTest --tests '*Board1DurableBoundary*'
// =====================================================================================================================

tasks.register<Test>("board1DurableBoundaryWorker") {
    group = "verification"
    description = "GS-INTEGRATION-001 scenarios (step 6): runs the Android durable-boundary recovery worker -- a " +
        "prepare JVM that halts at a named durable boundary and a fresh recovery JVM over the same on-disk estate."

    // The debug unit-test task's own classes and classpath, carried straight from it, so this worker runs on the SAME
    // Robolectric/sqlite-jdbc/junit runtime classpath the default suite uses with nothing hand-assembled to drift.
    val debugUnitTest = tasks.named<Test>("testDebugUnitTest")
    testClassesDirs = debugUnitTest.get().testClassesDirs
    classpath = debugUnitTest.get().classpath
    filter { includeTestsMatching("*Board1DurableBoundary*") }

    // An up-to-date worker is a stale green; retain the XML the coordinator consumes.
    outputs.upToDateWhen { false }
    reports.junitXml.required.set(true)
    reports.junitXml.outputLocation.set(layout.buildDirectory.dir("test-results/board1DurableBoundaryWorker"))
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = true
    }
    // *** THE SHARED KEY SPACE, PLUS THIS ISLE'S OWN TWO. ***
    //
    // *`boundary` is named EXPLICITLY rather than smuggled through `variant` -- the sibling worker still readeth
    // `variant`, so BOTH are forwarded and the boundary is read from `boundary` first.* **`holdForParentKill` is this
    // file's own switch: the parent campaign setteth it true so the child it spawneth waits to be killed and the
    // parent can prove the child was still alive at the fatal instant; an unset (empty) value is dropped by the
    // worker, and an empty value is an ABSENT one throughout** -- because this task forwards every unset key as an
    // empty string, and a worker that took "" for a role would refuse an ordinary run.
    listOf(
        "role", "root", "in", "out", "mode", "metadata", "variant", "deadlineSeconds",
        "boundary", "expectedMsgId", "holdForParentKill",
    ).forEach { key ->
        val name = "godstone.integration.$key"
        systemProperty(name, providers.systemProperty(name).getOrElse(""))
    }
    // The default JVM's own heap/fork settings are inherited; no daemon is started by this task beyond the wrapper's
    // own, and `--no-daemon` at the command line keeps a Gradle daemon out of the crash lane entirely.
    maxHeapSize = "2g"
}

// =====================================================================================================================
// *** GS-INTEGRATION-001 `scenarios`: THE REPLAY/ROTATION/PARITY LANE. ***
//
// *THE CARD (step 6) NAMETH TWO ADDITIONAL COVERS BESIDE THE DURABLE BOUNDARY: **"replay and rotation control
// coverage"** and **"30 scenarios"**, PLUS **"payload tests across 15 scenarios"** proving **the actual user messages
// reach the recipients intact.*** **Those arms live in `io.godstone.mesh.lab.replay` and
// `io.godstone.mesh.lab.payload`, so this task RUNNETH them EXPLICITLY** -- the same shape `board1IntegrationWorker`
// and `board1DurableBoundaryWorker` already carry, so a lane that selects them is a real selection rather than an
// empty one.
//
//   cd android && ./gradlew :mesh:board1ReplayLane --no-daemon
//
// =====================================================================================================================
tasks.register<Test>("board1ReplayLane") {
    group = "verification"
    description = "GS-INTEGRATION-001 scenarios: the replay/rotation control lane (initial handshake replay, the " +
        "bounded queue overflow, replay-after-reconnect, the rotation paths and the payload round-trip)."

    val debugUnitTest = tasks.named<Test>("testDebugUnitTest")
    testClassesDirs = debugUnitTest.get().testClassesDirs
    classpath = debugUnitTest.get().classpath
    filter { includeTestsMatching("io.godstone.mesh.lab.replay.*") }
    filter { includeTestsMatching("io.godstone.mesh.lab.payload.*") }

    outputs.upToDateWhen { false }
    reports.junitXml.required.set(true)
    reports.junitXml.outputLocation.set(layout.buildDirectory.dir("test-results/board1ReplayLane"))
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = true
    }
    maxHeapSize = "2g"
}
