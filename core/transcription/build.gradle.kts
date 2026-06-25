import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    targets.configureEach {
        compilations.configureEach {
            compileTaskProvider.configure {
                compilerOptions {
                    freeCompilerArgs.add("-Xexpect-actual-classes")
                }
            }
        }
    }

    jvm()
    androidTarget {
        @OptIn(ExperimentalKotlinGradlePluginApi::class)
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.compilations.getByName("main") {
            cinterops {
                create("osmemory") {
                    defFile("src/nativeInterop/cinterop/osmemory.def")
                }
            }
        }
    }

    sourceSets {
        val mobileMain by creating {
            dependsOn(commonMain.get())
            dependencies {
                implementation(project(":cactus"))
            }
        }
        val iosMain by creating {
            dependsOn(mobileMain)
            dependencies {
                implementation(libs.coredevices.speex)
            }
        }
        val iosArm64Main by getting {
            dependsOn(iosMain)
        }
        val iosSimulatorArm64Main by getting {
            dependsOn(iosMain)
        }
        commonMain.dependencies {
            implementation(libs.coroutines)
            implementation(libs.ktor.client.core)
            implementation(libs.ktor.client.websockets)
            implementation(libs.kotlinx.io.core)
            implementation(libs.serialization)
        }
        androidMain {
            dependsOn(mobileMain)
            dependencies {
                implementation(libs.coredevices.speex)
            }
        }
        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(libs.coroutines.test)
        }
        jvmTest.dependencies {
            implementation(libs.ktor.client.mock)
        }
    }
}

android {
    namespace = "dev.audiocompanion.transcription"
    compileSdk = libs.versions.android.compileSdk.get().toInt()
    defaultConfig {
        minSdk = libs.versions.android.minSdk.get().toInt()
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
