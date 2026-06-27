pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "pebble-audio-companion"

include(":core:protocol")
include(":core:transport")
include(":core:storage")
include(":core:transcription")
include(":core:ai")
include(":core:search")
include(":adapter:ble-android")
include(":adapter:ble-ios")
include(":app")
include(":cactus")
