plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvm()
    androidTarget {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    iosArm64()
    iosSimulatorArm64()

    sourceSets {
        commonMain.dependencies {
            implementation(libs.coroutines)
            implementation(libs.serialization)
        }
        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(libs.coroutines.test)
        }
        androidMain.dependencies {
            implementation(libs.androidx.core)
            implementation(libs.androidx.appsearch)
            implementation(libs.androidx.appsearch.local.storage)
            implementation(libs.coroutines.guava)
        }
    }
}

android {
    namespace = "dev.audiocompanion.search"
    compileSdk = libs.versions.android.compileSdk.get().toInt()
    defaultConfig {
        minSdk = libs.versions.android.minSdk.get().toInt()
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
