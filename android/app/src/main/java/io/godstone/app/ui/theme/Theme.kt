package io.godstone.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp

/**
 * Constraint C7: readable under stress. Large type, high contrast, and a red
 * night mode that preserves scotopic vision and hides the user at night.
 */
private val DarkScheme = darkColorScheme(
    primary = Color(0xFFE0A030),
    onPrimary = Color(0xFF1A1000),
    background = Color(0xFF0B0D10),
    onBackground = Color(0xFFE8EAED),
    surface = Color(0xFF14181D),
    onSurface = Color(0xFFE8EAED),
    error = Color(0xFFFF5449)
)

private val LightScheme = lightColorScheme(
    primary = Color(0xFF8A5A00),
    background = Color(0xFFFDFBF7),
    onBackground = Color(0xFF12140F),
    error = Color(0xFFBA1A1A)
)

/** Pure red on near-black. Used at night and at critical battery. */
private val NightRedScheme = darkColorScheme(
    primary = Color(0xFFFF3B30),
    onPrimary = Color(0xFF000000),
    background = Color(0xFF000000),
    onBackground = Color(0xFFFF4136),
    surface = Color(0xFF0A0000),
    onSurface = Color(0xFFFF4136),
    error = Color(0xFFFF6B6B)
)

private val GodstoneType = Typography(
    bodyLarge = TextStyle(fontSize = 18.sp, lineHeight = 27.sp),
    bodyMedium = TextStyle(fontSize = 16.sp, lineHeight = 24.sp),
    titleLarge = TextStyle(fontSize = 24.sp, lineHeight = 32.sp)
)

@Composable
fun GodstoneTheme(
    redNightMode: Boolean = false,
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val scheme = when {
        redNightMode -> NightRedScheme
        darkTheme -> DarkScheme
        else -> LightScheme
    }
    MaterialTheme(colorScheme = scheme, typography = GodstoneType, content = content)
}
