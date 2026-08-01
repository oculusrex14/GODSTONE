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

    // Tier flavors. Each ships a different model and archive database.
    flavorDimensions += "tier"

    productFlavors {
        create("light") {
            dimension = "tier"
            applicationIdSuffix = ".light"
            versionNameSuffix = "-light"
            buildConfigField("String", "TIER", "\"LIGHT\"")
            buildConfigField("String", "MODEL_FILE", "\"qwen3-0.6b-q4km.gguf\"")
            buildConfigField("String", "ARCHIVE_FILE", "\"archive_light.db\"")
            buildConfigField("int", "CTX_TOKENS", "2048")
            buildConfigField("int", "TOP_K_CHUNKS", "4")
            buildConfigField("String", "EMBED_MODEL_FILE", "\"\"")
            buildConfigField("int", "EMBED_DIM", "384")
        }
        create("medium") {
            dimension = "tier"
            applicationIdSuffix = ".medium"
            versionNameSuffix = "-medium"
            buildConfigField("String", "TIER", "\"MEDIUM\"")
            buildConfigField("String", "MODEL_FILE", "\"qwen3-1.7b-q4km.gguf\"")
            buildConfigField("String", "ARCHIVE_FILE", "\"archive_medium.db\"")
            buildConfigField("int", "CTX_TOKENS", "4096")
            buildConfigField("int", "TOP_K_CHUNKS", "6")
            buildConfigField("String", "EMBED_MODEL_FILE", "\"\"")
            buildConfigField("int", "EMBED_DIM", "384")
        }
        create("large") {
            dimension = "tier"
            applicationIdSuffix = ".large"
            versionNameSuffix = "-large"
            buildConfigField("String", "TIER", "\"LARGE\"")
            buildConfigField("String", "MODEL_FILE", "\"qwen3-4b-q5km.gguf\"")
            buildConfigField("String", "ARCHIVE_FILE", "\"archive_large.db\"")
            buildConfigField("int", "CTX_TOKENS", "8192")
            buildConfigField("int", "TOP_K_CHUNKS", "8")
            buildConfigField("String", "EMBED_MODEL_FILE", "\"\"")
            buildConfigField("int", "EMBED_DIM", "768")
        }
    }

    buildTypes {
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

    kotlinOptions {
        jvmTarget = "17"
    }

    // Model and archive assets must never be compressed: we mmap them at runtime.
    androidResources {
        noCompress += listOf("gguf", "db")
    }

    // The model and archive are mmap'd from assets at runtime. Without this
    // sourceSet the app installs, launches, and then cannot find its model on
    // a device that by definition cannot download it (C1).
    sourceSets {
        getByName("light")  { assets.srcDirs("src/light/assets",  "../../models", "../../dist") }
        getByName("medium") { assets.srcDirs("src/medium/assets", "../../models", "../../dist") }
        getByName("large")  { assets.srcDirs("src/large/assets",  "../../models", "../../dist") }
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":mesh"))
    implementation(project(":llm"))

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
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
