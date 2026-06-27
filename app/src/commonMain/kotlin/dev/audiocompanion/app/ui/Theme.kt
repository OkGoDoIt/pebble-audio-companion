package dev.audiocompanion.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The Pebble Audio Companion design system: one curated theme so every screen shares the same
 * palette, type scale, and corner language instead of inheriting bare Material 3 defaults. The
 * direction is a refined, light, indigo-violet productivity utility (ux plan Section 14: clean
 * backgrounds, high-contrast text, restrained accent, clear hierarchy).
 */

// --- palette ------------------------------------------------------------------------------------

private val Indigo = Color(0xFF5B5BD6) // primary accent
private val IndigoPressed = Color(0xFF4848C4)

private val LightColors = lightColorScheme(
    primary = Indigo,
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFE6E5FB),
    onPrimaryContainer = Color(0xFF1E1B4B),
    secondary = Color(0xFF5C5A72),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFE7E5F2),
    onSecondaryContainer = Color(0xFF1B1A2B),
    tertiary = Color(0xFF1565C0),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFD7E6FB),
    onTertiaryContainer = Color(0xFF0A2647),
    background = Color(0xFFFBFAFF),
    onBackground = Color(0xFF1B1A22),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF1B1A22),
    surfaceVariant = Color(0xFFEEECF6),
    onSurfaceVariant = Color(0xFF6B6880),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF7F5FD),
    surfaceContainer = Color(0xFFF3F1FB),
    surfaceContainerHigh = Color(0xFFEEECF7),
    surfaceContainerHighest = Color(0xFFE9E6F3),
    outline = Color(0xFFCFCCDE),
    outlineVariant = Color(0xFFE6E3F0),
    error = Color(0xFFB3261E),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFF9DEDC),
    onErrorContainer = Color(0xFF410E0B),
    scrim = Color(0x99000000),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFB9B8F4),
    onPrimary = Color(0xFF22215A),
    primaryContainer = Color(0xFF3A3992),
    onPrimaryContainer = Color(0xFFE6E5FB),
    secondary = Color(0xFFC6C3DC),
    onSecondary = Color(0xFF2D2C40),
    secondaryContainer = Color(0xFF3F3D52),
    onSecondaryContainer = Color(0xFFE7E5F2),
    tertiary = Color(0xFFA8C8F5),
    onTertiary = Color(0xFF0A2647),
    background = Color(0xFF111017),
    onBackground = Color(0xFFE7E4F1),
    surface = Color(0xFF16151D),
    onSurface = Color(0xFFE7E4F1),
    surfaceVariant = Color(0xFF2A2833),
    onSurfaceVariant = Color(0xFFA8A4B8),
    surfaceContainerLowest = Color(0xFF0F0E15),
    surfaceContainerLow = Color(0xFF1A1922),
    surfaceContainer = Color(0xFF1E1D27),
    surfaceContainerHigh = Color(0xFF29272F),
    surfaceContainerHighest = Color(0xFF34323B),
    outline = Color(0xFF49475A),
    outlineVariant = Color(0xFF332F3D),
    error = Color(0xFFF2B8B5),
    onError = Color(0xFF601410),
    errorContainer = Color(0xFF8C1D18),
    onErrorContainer = Color(0xFFF9DEDC),
    scrim = Color(0x99000000),
)

// --- type scale ---------------------------------------------------------------------------------

// Uses the platform system family (SF on iOS, Roboto on Android). The scale is a touch tighter and
// the weights more deliberate than the M3 baseline so screens read as designed, not default.
private val AppTypography = Typography().run {
    copy(
        displaySmall = displaySmall.copy(fontWeight = FontWeight.SemiBold),
        headlineLarge = headlineLarge.tuned(32.sp, 38.sp, FontWeight.Bold, (-0.4).sp),
        headlineMedium = headlineMedium.tuned(26.sp, 32.sp, FontWeight.Bold, (-0.3).sp),
        headlineSmall = headlineSmall.tuned(21.sp, 27.sp, FontWeight.SemiBold, (-0.2).sp),
        titleLarge = titleLarge.tuned(20.sp, 26.sp, FontWeight.SemiBold, (-0.2).sp),
        titleMedium = titleMedium.tuned(16.sp, 22.sp, FontWeight.SemiBold, 0.sp),
        titleSmall = titleSmall.tuned(13.sp, 18.sp, FontWeight.SemiBold, 0.1.sp),
        bodyLarge = bodyLarge.tuned(16.sp, 23.sp, FontWeight.Normal, 0.1.sp),
        bodyMedium = bodyMedium.tuned(14.sp, 20.sp, FontWeight.Normal, 0.1.sp),
        bodySmall = bodySmall.tuned(13.sp, 18.sp, FontWeight.Normal, 0.1.sp),
        labelLarge = labelLarge.tuned(14.sp, 18.sp, FontWeight.SemiBold, 0.1.sp),
        labelMedium = labelMedium.tuned(12.sp, 16.sp, FontWeight.Medium, 0.3.sp),
        labelSmall = labelSmall.tuned(11.sp, 15.sp, FontWeight.Medium, 0.4.sp),
    )
}

private fun TextStyle.tuned(
    size: androidx.compose.ui.unit.TextUnit,
    lineHeight: androidx.compose.ui.unit.TextUnit,
    weight: FontWeight,
    letterSpacing: androidx.compose.ui.unit.TextUnit,
): TextStyle = copy(fontSize = size, lineHeight = lineHeight, fontWeight = weight, letterSpacing = letterSpacing)

// --- shapes -------------------------------------------------------------------------------------

private val AppShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

// --- spacing tokens -----------------------------------------------------------------------------

/** Shared spacing scale so padding is consistent across screens instead of ad-hoc magic numbers. */
object Spacing {
    val screenH = 16.dp
    val section = 22.dp
    val gap = 12.dp
    val tight = 8.dp
    val hair = 4.dp
}

@Composable
fun AudioCompanionTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = AppTypography,
        shapes = AppShapes,
        content = content,
    )
}
