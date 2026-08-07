plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
}

android {
    namespace = "io.godstone.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.godstone.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // One application identity and one initially shippable tier. MEDIUM and
    // LARGE remain source-level research configurations until independently
    // measured and given a store-compatible asset delivery design.
    flavorDimensions += "tier"
    productFlavors {
        create("light") {
            dimension = "tier"
            buildConfigField("String", "TIER", "\"LIGHT\"")
            buildConfigField("String", "MODEL_FILE", "\"qwen3-0.6b-q4km.gguf\"")
            buildConfigField("String", "ARCHIVE_FILE", "\"archive_light.db\"")
            buildConfigField("int", "CTX_TOKENS", "2048")
            buildConfigField("int", "TOP_K_CHUNKS", "4")
            buildConfigField("String", "EMBED_MODEL_FILE", "\"\"")
            buildConfigField("int", "EMBED_DIM", "384")
            buildConfigField("boolean", "ORACLE_ENABLED", "false")
            buildConfigField("boolean", "MESH_ENABLED", "false")
            buildConfigField("boolean", "SOS_ENABLED", "false")
            buildConfigField("boolean", "BULK_TRANSFER_ENABLED", "false")
        }
    }

    buildTypes {
        debug {
            // Disabled features stay disabled in debug unless a developer uses
            // a separate, nonshipping experimental source set.
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    androidResources { noCompress += listOf("gguf", "db") }

    // Assets are staged into this single variant directory only by
    // scripts/prepare_release_assets.py after hash/tier/review verification.
    sourceSets {
        named("light") { assets.setSrcDirs(listOf("src/light/assets")) }
    }
    // Disabled transport UI (Mesh/SOS) is not compiled into the production app.
    // These `java.exclude(...)` globs are BUILD-CONFIG EVIDENCE consumed by the
    // shipping-path gate (ci/check_shipping_path.py): it reads them to decide
    // which sources are dormant debt (excluded) vs. shipping (included). The
    // bare `java` accessor is shadowed by a project-scope extension inside a
    // `named("main") { ... }` lambda (Gradle Kotlin DSL resolves it to a
    // Configuration, not the sourceSet's java directory set), so the excludes
    // are applied through a typed sourceSet reference, where member access
    // wins. The gate applies these globs to BOTH src/main/java (shipping
    // sources) and src/main/dormant/java (where the dormant Mesh/SOS .kt
    // files physically live) so that dropping a glob would re-include the
    // dormant file and fail the gate (selftest sanity control).
    sourceSets.getByName("main").java.exclude("io/godstone/app/ui/mesh/**")
    sourceSets.getByName("main").java.exclude("io/godstone/app/ui/sos/**")
    // The dormant Mesh/SOS UI screens physically live under src/main/dormant/java
    // (NOT src/main/java). AGP/KGP auto-wires src/main/java and src/main/kotlin
    // as Kotlin SOURCE DIRECTORIES and this cannot be prevented:
    // KotlinCompile.getSources() (KGP; no longer extends AbstractCompile since
    // Gradle 7) enumerates those directories with a **/*.kt include and IGNORES
    // SourceDirectorySet.exclude() metadata (verified empirically: excludes
    // registered on AGP's AndroidSourceSet.kotlin and on KGP's
    // KotlinSourceSet.kotlin were both ignored, and setSrcDirs on either was
    // overridden -- KGP re-adds src/main/java after evaluation). The dormant
    // screens reference symbols only present in the non-shipping :mesh module,
    // so they CANNOT compile. The only deterministic lever KGP/AGP honours is
    // which directories are source directories at all: KGP auto-wires
    // src/<sourceSet>/{java,kotlin} only, so src/main/dormant/java is NOT a
    // source directory and its .kt files are never compiled. The gate still
    // scans src/main/dormant/java and the java.exclude globs above classify
    // those files as dormant debt, so the gate's evidence and sanity control
    // are preserved while the build finally honours the exclusion.
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
    lint {
        abortOnError = true
        checkReleaseBuilds = true
        warningsAsErrors = true
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":llm"))  // compiled for safety tests; Oracle route is absent

    implementation(platform("androidx.compose:compose-bom:2024.09.02"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.navigation:navigation-compose:2.8.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")

    implementation("com.google.dagger:hilt-android:2.52")
    ksp("com.google.dagger:hilt-compiler:2.52")
    implementation("androidx.hilt:hilt-navigation-compose:1.2.0")

    testImplementation("junit:junit:4.13.2")
    // JVM unit tests for the Oracle state machine: drive OracleViewModel against
    // a fake OraclePipeline with no native model on the classpath.
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.6")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
