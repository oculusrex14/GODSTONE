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
        getByName("main") {
            // Disabled transport UI is not compiled into the production app.
            java.exclude("io/godstone/app/ui/mesh/**")
            java.exclude("io/godstone/app/ui/sos/**")
        }
        getByName("light") { assets.setSrcDirs(listOf("src/light/assets")) }
    }

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
