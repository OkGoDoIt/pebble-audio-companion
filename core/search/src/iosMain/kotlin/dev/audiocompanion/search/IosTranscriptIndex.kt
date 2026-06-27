package dev.audiocompanion.search

/**
 * iOS transcript index: in-memory BM25-style search for Ask retrieval. Core Spotlight donation is
 * handled by the Swift shell ([SpotlightDonationBridge]) when native indexing is available.
 */
class IosTranscriptIndex : InMemoryTranscriptIndex()

fun createIosTranscriptIndex(): TranscriptIndex = IosTranscriptIndex()
