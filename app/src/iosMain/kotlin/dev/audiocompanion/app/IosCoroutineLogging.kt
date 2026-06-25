package dev.audiocompanion.app

import kotlinx.coroutines.CoroutineExceptionHandler
import platform.Foundation.NSLog

internal fun iosCoroutineExceptionHandler(component: String): CoroutineExceptionHandler =
    CoroutineExceptionHandler { _, throwable ->
        NSLog(
            "Pebble Audio Companion $component coroutine failed: " +
                "${throwable::class.simpleName ?: "Throwable"}: ${throwable.message ?: ""}",
        )
        logBackgroundFailure("$component coroutine", throwable)
    }
