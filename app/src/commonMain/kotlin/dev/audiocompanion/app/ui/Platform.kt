package dev.audiocompanion.app.ui

/**
 * True on iOS, false elsewhere. The UI is intentionally shared across platforms; this flag exists
 * so a small, deliberate set of affordances can read as native per platform — the back-button glyph
 * (iOS chevron vs. Material arrow), the share icon (iOS share-sheet box vs. Material share), and the
 * bottom tab bar (iOS tinted tabs vs. the Material pill indicator). Keep platform branches narrow:
 * prefer one shared component that adapts over forking whole screens.
 */
expect val isIOS: Boolean
