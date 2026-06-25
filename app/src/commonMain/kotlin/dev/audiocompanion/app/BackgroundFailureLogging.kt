package dev.audiocompanion.app

internal fun logBackgroundFailure(component: String, throwable: Throwable) {
    println(
        "Pebble Audio Companion $component failed: " +
            "${throwable::class.simpleName ?: "Throwable"}: ${throwable.message.orEmpty()}",
    )
    throwable.printStackTrace()
}
