# Godstone ProGuard / R8 rules.
#
# Constraint C1: the app ships minified release builds, so keep what R8 must not
# touch: the JNI bridge, Hilt-injected ViewModels, BuildConfig, and the crypto
# libraries that ship their own rules under META-INF.
#
# NOTE: llama.cpp native symbols are exported and kept by the C++ build
# (CMakeLists / externalNativeBuild), not by these rules; we only need to keep
# the Kotlin declarations that the JVM-side reflection and JNI lookup require.

# --- JNI bridge: keep the class and its native method signatures -------------
-keep class io.godstone.llm.LlamaBridge {
    native <methods>;
}
# Keep native method names from being obfuscated across the whole codebase.
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- Model bridge surface: keep the llm package intact for reflective access --
-keep class io.godstone.llm.** { *; }

# --- Hilt ViewModels: keep members so Hilt can inject and Compose can read ----
-keepclassmembers class * extends androidx.lifecycle.ViewModel {
    *;
}

# --- BuildConfig is read reflectively at runtime -----------------------------
-keep class io.godstone.app.BuildConfig { *; }

# --- Third-party crypto: they ship their own rules; silence missing-class warns -
-dontwarn org.bouncycastle.**
-dontwarn com.southernstorm.**
-dontwarn net.zetetic.**