package dev.audiocompanion.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.unit.dp
import dev.audiocompanion.app.WaveformBar
import dev.audiocompanion.app.WaveformBarState

/**
 * The live waveform of the last ~60 seconds (ux plan Section 8): newest audio enters at the
 * right edge and scrolls left. Bars are positioned by time, so periods with no received audio
 * read as empty space, never as fake audio. Colors: accent = recorded, blue = transcribed,
 * gray = detected silence, amber = gap.
 */
@Composable
fun LiveWaveform(
    bars: List<WaveformBar>,
    windowMs: Long,
    nowMs: Long,
    isSegmentTranscribed: (String) -> Boolean,
    modifier: Modifier = Modifier,
) {
    val recordedColor = MaterialTheme.colorScheme.primary
    Column(modifier = modifier.fillMaxWidth()) {
        Canvas(modifier = Modifier.fillMaxWidth().height(56.dp)) {
            val width = size.width
            val centerY = size.height / 2f
            val barWidth = (width * 1000f / windowMs).coerceAtLeast(1.5f)
            for (bar in bars) {
                val age = nowMs - bar.timeMs
                if (age < 0 || age > windowMs) continue
                val x = width - (age.toFloat() / windowMs) * width
                val color: Color
                val halfHeight: Float
                when {
                    bar.state == WaveformBarState.Gap -> {
                        color = StatusColors.warning
                        halfHeight = centerY * 0.9f
                    }
                    bar.state == WaveformBarState.Silence -> {
                        color = StatusColors.neutral
                        halfHeight = (centerY * 0.06f).coerceAtLeast(1f)
                    }
                    bar.segmentId?.let(isSegmentTranscribed) == true -> {
                        color = StatusColors.info
                        halfHeight = (centerY * bar.amplitude).coerceAtLeast(2f)
                    }
                    else -> {
                        color = recordedColor
                        halfHeight = (centerY * bar.amplitude).coerceAtLeast(2f)
                    }
                }
                drawLine(
                    color = color,
                    start = Offset(x, centerY - halfHeight),
                    end = Offset(x, centerY + halfHeight),
                    strokeWidth = barWidth * 0.8f,
                    cap = StrokeCap.Round,
                )
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text = "60 sec ago",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = "now",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
