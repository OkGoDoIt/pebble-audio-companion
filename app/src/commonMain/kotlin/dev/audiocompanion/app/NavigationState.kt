package dev.audiocompanion.app

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One-shot navigation request (Spotlight tap, action-item source link, etc.). */
data class AppNavigationRequest(
    val tab: AppTab,
    val librarySegmentId: String? = null,
)

/**
 * Shared navigation spine for deep links and in-app "open segment" actions.
 */
class NavigationState {
    private val _pending = MutableStateFlow<AppNavigationRequest?>(null)
    val pending: StateFlow<AppNavigationRequest?> = _pending.asStateFlow()

    fun openLibrarySegment(segmentId: String) {
        _pending.value = AppNavigationRequest(tab = AppTab.Library, librarySegmentId = segmentId)
    }

    fun consumePending(): AppNavigationRequest? {
        val req = _pending.value
        _pending.value = null
        return req
    }
}
