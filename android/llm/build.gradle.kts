plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.godstone.llm"
    compileSdk = 35

    defaultConfig {
        minSdk = 26

        externalNativeBuild {
            cmake {
                // Enable ARM dot product and i8mm where the SoC supports them.
                // These roughly double int8 throughput on modern cores.
                cppFlags += listOf("-O3", "-fno-exceptions", "-fno-rtti")
                arguments += listOf(
                    "-DGGML_LLAMAFILE=ON",
                    "-DGGML_OPENMP=OFF",
                    "-DLLAMA_BUILD_EXAMPLES=OFF",
                    "-DLLAMA_BUILD_TESTS=OFF"
                )
            }
        }

        ndk {
            // arm64 only. 32-bit devices cannot mmap a multi-GB model anyway.
            abiFilters += listOf("arm64-v8a")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
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
    implementation("androidx.sqlite:sqlite-ktx:2.4.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlin:kotlin-test:2.0.20")
}
