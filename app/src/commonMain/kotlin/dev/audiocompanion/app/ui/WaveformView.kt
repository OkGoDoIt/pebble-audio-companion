package dev.audiocompanion.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import dev.audiocompanion.app.SegmentWaveform
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
    barMs: Long = 250,
    /** Live-transcribed boundary per segment: bars at/before it render as transcribed. */
    transcribedThroughSampleIndex: (String) -> ULong? = { null },
) {
    val recordedColor = MaterialTheme.colorScheme.primary
    Column(modifier = modifier.fillMaxWidth()) {
        // Same visual language as the Library segment waveform: thin rounded bars around a
        // center line, one per time bucket.
        Canvas(modifier = Modifier.fillMaxWidth().height(64.dp)) {
            val width = size.width
            val centerY = size.height / 2f
            val barWidth = (width * barMs.toFloat() / windowMs * 0.8f).coerceAtLeast(1f)
            for (bar in bars) {
                val age = nowMs - bar.timeMs
                if (age < 0 || age > windowMs) continue
                val x = width - (age.toFloat() / windowMs) * width
                val transcribed = bar.segmentId != null && (
                    isSegmentTranscribed(bar.segmentId) ||
                        bar.maxSampleIndex?.let { sample ->
                            transcribedThroughSampleIndex(bar.segmentId)
                                ?.let { boundary -> sample < boundary } == true
                        } == true
                    )
                val color: Color
                val halfHeight: Float
                var strokeWidth = barWidth
                when {
                    bar.state == WaveformBarState.Gap -> {
                        color = StatusColors.warning
                        halfHeight = centerY * 0.9f
                    }
                    bar.state == WaveformBarState.SuppressedSilence -> {
                        // Voice-activity silence the watch skipped: a subtle thin grey tick at the
                        // same minimal height as quiet audio, but greyer and narrower so it reads
                        // as "intentionally quiet here", not as missing audio or a dropped link.
                        color = StatusColors.neutral.copy(alpha = 0.5f)
                        halfHeight = (centerY * 0.06f).coerceAtLeast(1.5f)
                        strokeWidth = (barWidth * 0.5f).coerceAtLeast(1f)
                    }
                    bar.state == WaveformBarState.Silence -> {
                        color = StatusColors.neutral
                        halfHeight = (centerY * 0.06f).coerceAtLeast(1f)
                    }
                    transcribed -> {
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
                    strokeWidth = strokeWidth,
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
        WaveformLegend(showTranscribed = true)
    }
}

/** Explains the waveform colors (user requirement: every waveform carries a legend). */
@Composable
fun WaveformLegend(
    showTranscribed: Boolean,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth().padding(top = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LegendEntry(MaterialTheme.colorScheme.primary, "Audio")
        if (showTranscribed) LegendEntry(StatusColors.info, "Transcribed")
        LegendEntry(StatusColors.neutral, "Quiet")
        LegendEntry(StatusColors.warning, "Missing")
    }
}

@Composable
private fun LegendEntry(color: Color, label: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(modifier = Modifier.size(8.dp).background(color, CircleShape))
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Waveform of one stored segment (Library detail): bars over media time colored by audio
 * status, amber markers where audio is missing, a playback cursor, and tap-to-seek.
 */
@Composable
fun SegmentWaveformView(
    waveform: SegmentWaveform,
    positionFraction: Float?,
    onSeekFraction: ((Float) -> Unit)?,
    modifier: Modifier = Modifier,
    /** Audio bars left of this media-time fraction render as transcribed (blue). */
    transcribedFraction: Float? = null,
) {
    val recordedColor = MaterialTheme.colorScheme.primary
    val cursorColor = MaterialTheme.colorScheme.onSurface
    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(64.dp)
            .let { base ->
                if (onSeekFraction == null) {
                    base
                } else {
                    // The waveform is the segment's only progress bar, so it must support
                    // both tap-to-seek and drag-to-scrub.
                    base
                        .pointerInput(waveform) {
                            detectTapGestures { offset ->
                                onSeekFraction((offset.x / size.width).coerceIn(0f, 1f))
                            }
                        }
                        .pointerInput(waveform) {
                            detectHorizontalDragGestures { change, _ ->
                                change.consume()
                                onSeekFraction((change.position.x / size.width).coerceIn(0f, 1f))
                            }
                        }
                }
            },
    ) {
        val width = size.width
        val centerY = size.height / 2f
        if (waveform.bars.isNotEmpty()) {
            val step = width / waveform.bars.size
            val stroke = (step * 0.8f).coerceAtLeast(1f)
            waveform.bars.forEachIndexed { index, bar ->
                val x = step * (index + 0.5f)
                val transcribed = transcribedFraction != null &&
                    (index + 0.5f) / waveform.bars.size <= transcribedFraction
                val color: Color
                val halfHeight: Float
                when {
                    bar.state == WaveformBarState.Silence ||
                        bar.state == WaveformBarState.SuppressedSilence -> {
                        color = StatusColors.neutral
                        halfHeight = (centerY * 0.06f).coerceAtLeast(1f)
                    }
                    transcribed -> {
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
                    strokeWidth = stroke,
                    cap = StrokeCap.Round,
                )
            }
        }
        // Missing-audio markers: thin full-height ticks where genuine audio loss occurred.
        // Silence the watch skipped to save power is not loss and carries no marker.
        waveform.gapMarkers.forEach { marker ->
            val x = (marker.fraction * width).coerceIn(0f, width)
            drawLine(
                color = StatusColors.warning,
                start = Offset(x, centerY * 0.1f),
                end = Offset(x, size.height - centerY * 0.1f),
                strokeWidth = 2.5f,
                cap = StrokeCap.Round,
            )
        }
        positionFraction?.let { fraction ->
            val x = (fraction * width).coerceIn(0f, width)
            drawLine(
                color = cursorColor,
                start = Offset(x, 0f),
                end = Offset(x, size.height),
                strokeWidth = 2f,
            )
        }
    }
}
