plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
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

    // Noise Protocol Framework, Java reference implementation.
    implementation("com.southernstorm:noise-java:1.0")

    // BouncyCastle for BLAKE2s and Ed25519 where the platform lacks them.
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")

    // Encrypted local storage for the message store (threat A6).
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("net.zetetic:sqlcipher-android:4.6.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test:2.0.20")
}
