plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
    `maven-publish`
}

val sdkVersion: String by rootProject.extra

android {
    namespace = "com.tododdle.support"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        buildConfigField("String", "SDK_VERSION", "\"$sdkVersion\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

kotlin {
    explicitApi()
}

dependencies {
    api(libs.coroutines.core)
    api(libs.okhttp)
    implementation(libs.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.coroutines.test)
}

tasks.withType<Test>().configureEach {
    // The shared conformance cases live outside the Gradle build, at /contract/cases.
    systemProperty("tododdle.casesFile", rootDir.resolve("../contract/cases/cases.json").absolutePath)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            artifactId = "support"
            afterEvaluate { from(components["release"]) }
        }
    }
}
