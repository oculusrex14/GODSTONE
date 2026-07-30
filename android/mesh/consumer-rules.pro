# Consumer ProGuard rules for the :mesh library.
#
# The mesh module ships crypto and JNI-adjacent libraries that the consumer app
# must not strip or rename. The consumer app may otherwise shrink its own code.

# BouncyCastle: BLAKE2s, Ed25519, X25519 -- reflection and algorithm lookups.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# Noise Protocol Framework, Java reference implementation.
-keep class com.southernstorm.** { *; }
-dontwarn com.southernstorm.**

# SQLCipher native bridge.
-keep class net.zetetic.** { *; }
-dontwarn net.zetetic.**

# Mesh public API and serialised wire types.
-keep class io.godstone.mesh.** { *; }