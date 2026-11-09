plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// The SDK version comes from /VERSION at the repository root.
val sdkVersion: String = rootDir.resolve("../VERSION").readText().trim()

// JitPack sets JITPACK=true, GROUP=com.github.<owner> and VERSION=<tag>. It serves multi-module
// builds as com.github.<owner>.<repo>:<module>:<tag>, so publish with that group there.
val onJitPack = System.getenv("JITPACK") == "true"
val publishGroup: String =
    if (onJitPack) "${System.getenv("GROUP") ?: "com.github.krffl"}.tododdle-support" else "com.tododdle"
val publishVersion: String = if (onJitPack) System.getenv("VERSION") ?: sdkVersion else sdkVersion

extra["sdkVersion"] = sdkVersion

subprojects {
    group = publishGroup
    version = publishVersion
}
