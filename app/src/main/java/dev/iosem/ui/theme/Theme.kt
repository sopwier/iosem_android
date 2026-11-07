package dev.iosem.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Mint = Color(0xFF6EE7B7)
private val Sky = Color(0xFF93C5FD)
private val Ink = Color(0xFF0B0F12)
private val Panel = Color(0xFF12181D)
private val PanelHigh = Color(0xFF1A2229)
private val TextMain = Color(0xFFE6EDF3)
private val TextMuted = Color(0xFF8B9AA8)

private val Colors = darkColorScheme(
    primary = Mint,
    onPrimary = Color(0xFF06251B),
    primaryContainer = Color(0xFF123B2E),
    onPrimaryContainer = Mint,
    secondary = Sky,
    onSecondary = Color(0xFF0A1B2E),
    background = Ink,
    onBackground = TextMain,
    surface = Panel,
    onSurface = TextMain,
    surfaceVariant = PanelHigh,
    onSurfaceVariant = TextMuted,
    outline = Color(0xFF2A343D),
    error = Color(0xFFFCA5A5),
    onError = Color(0xFF2A0A0A),
)

@Composable
fun IosemTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = Colors,
        typography = Typography(),
        content = content,
    )
}
