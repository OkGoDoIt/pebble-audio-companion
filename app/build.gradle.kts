import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.application)
    alias(libs.plugins.composeMultiplatform)
    alias(libs.plugins.composeCompiler)
}

kotlin {
    androidTarget {
        @OptIn(ExperimentalKotlinGradlePluginApi::class)
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    listOf(
        iosArm64(),
        iosSimulatorArm64(),
    ).forEach { target ->
        target.binaries.framework {
            baseName = "AudioCompanionApp"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(project(":core:protocol"))
            implementation(project(":core:transport"))
            implementation(project(":core:storage"))
            implementation(project(":core:transcription"))
            implementation(project(":core:ai"))
            implementation(project(":core:search"))
            implementation(libs.coroutines)
            implementation(libs.kotlinx.datetime)
            implementation(libs.kotlinx.io.core)
            implementation(libs.koin.core)
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.materialIconsExtended)
            implementation(compose.ui)
            // Multiplatform BackHandler/PredictiveBackHandler. On iOS this is what makes the system
            // edge swipe-back gesture pop our in-app navigation stack (enableBackGesture defaults to
            // true on ComposeUIViewController); on Android it bridges to the OnBackPressedDispatcher.
            implementation("org.jetbrains.compose.ui:ui-backhandler:${libs.versions.compose.multiplatform.get()}")
        }
        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(libs.coroutines.test)
        }
        androidMain.dependencies {
            implementation(project(":adapter:ble-android"))
            implementation(libs.androidx.activity.compose)
            implementation(libs.androidx.core)
            implementation(libs.androidx.core.google.shortcuts)
            implementation(libs.androidx.work.runtime)
            implementation(libs.ktor.client.okhttp)
            // On-device AI (Gemini Nano via AICore). Absent at runtime on unsupported devices, which
            // the provider handles by reporting unavailable.
            implementation("com.google.mlkit:genai-prompt:1.0.0-beta2")
        }
        iosMain.dependencies {
            implementation(project(":adapter:ble-ios"))
            implementation(libs.ktor.client.darwin)
            implementation(libs.ktor.client.websockets)
            implementation(libs.okio)
        }
    }
}

android {
    namespace = "dev.audiocompanion.app"
    compileSdk = libs.versions.android.compileSdk.get().toInt()
    defaultConfig {
        applicationId = "dev.audiocompanion.app"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 1
        versionName = "0.1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
