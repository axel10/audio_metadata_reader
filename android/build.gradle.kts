// Android Gradle script configured for the audio_metadata_reader library.
// It defines the compilation configuration, package namespace, JVM target, and dependencies.
group = "com.clementbeal.audio_metadata_reader"
version = "1.6.0"

plugins {
    id("com.android.library")
    id("kotlin-android")
}

configure<com.android.build.api.dsl.LibraryExtension> {
    namespace = "com.clementbeal.audio_metadata_reader"
    compileSdk = 34

    defaultConfig {
        minSdk = 21
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib")
}
