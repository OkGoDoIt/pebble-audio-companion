package dev.audiocompanion.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.app.LocalTranscriptionModelState
import dev.audiocompanion.protocol.AuthStatus
import dev.audiocompanion.transport.ReceiverSessionState

/** Steps of the setup wizard (ux plan Section 7). */
enum class OnboardingStep(val title: String) {
    Welcome("Pebble Audio Companion"),
    Requirements("Before you start"),
    Permissions("Permissions"),
    FindWatch("Find your watch"),
    WatchConsent("Confirm on your watch"),
    PrivacyDefaults("Privacy choices"),
    Ready("Ready"),
}

/**
 * The stateful onboarding wizard (MVP requirement). Shown until completed once; completion is
 * persisted via settings so reinstalls re-onboard but restarts do not.
 */
@Composable
fun OnboardingScreen(
    sessionState: ReceiverSessionState,
    settings: AudioCompanionSettings,
    localModel: LocalTranscriptionModelState,
    actions: AppActions,
) {
    var step by rememberSaveable { mutableStateOf(OnboardingStep.Welcome) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Spacer(modifier = Modifier.height(24.dp))
        LinearProgressIndicator(
            progress = { (step.ordinal + 1) / OnboardingStep.entries.size.toFloat() },
            modifier = Modifier.fillMaxWidth(),
        )
        Text(text = step.title, style = MaterialTheme.typography.headlineMedium)

        when (step) {
            OnboardingStep.Welcome -> WelcomeStep(onNext = { step = OnboardingStep.Requirements })

            OnboardingStep.Requirements -> RequirementsStep(
                onBack = { step = OnboardingStep.Welcome },
                onNext = { step = OnboardingStep.Permissions },
            )

            OnboardingStep.Permissions -> PermissionsStep(
                onRequest = actions.requestPermissions,
                onBack = { step = OnboardingStep.Requirements },
                onNext = { step = OnboardingStep.FindWatch },
            )

            OnboardingStep.FindWatch -> FindWatchStep(
                sessionState = sessionState,
                onFind = actions.pairWatch,
                onBack = { step = OnboardingStep.Permissions },
                onNext = { step = OnboardingStep.WatchConsent },
            )

            OnboardingStep.WatchConsent -> WatchConsentStep(
                sessionState = sessionState,
                onRetry = actions.pairWatch,
                onBack = { step = OnboardingStep.FindWatch },
                onNext = { step = OnboardingStep.PrivacyDefaults },
            )

            OnboardingStep.PrivacyDefaults -> PrivacyDefaultsStep(
                settings = settings,
                localModel = localModel,
                actions = actions,
                onBack = { step = OnboardingStep.WatchConsent },
                onNext = { step = OnboardingStep.Ready },
            )

            OnboardingStep.Ready -> ReadyStep(
                sessionState = sessionState,
                settings = settings,
                onStart = {
                    actions.setBackgroundReceiverEnabled(true)
                    actions.startReceiver()
                    actions.setOnboardingComplete(true)
                },
                onDone = { actions.setOnboardingComplete(true) },
            )
        }
        Spacer(modifier = Modifier.height(24.dp))
    }
}

@Composable
private fun StepButtons(
    onBack: (() -> Unit)?,
    onNext: () -> Unit,
    nextLabel: String = "Continue",
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (onBack != null) {
            OutlinedButton(onClick = onBack) { Text("Back") }
        }
        Button(onClick = onNext) { Text(nextLabel) }
    }
}

@Composable
private fun WelcomeStep(onNext: () -> Unit) {
    var showHow by rememberSaveable { mutableStateOf(false) }
    Text(
        text = "Receive audio from your Pebble, store it on this phone, and turn it into " +
            "transcripts and notes. The official Pebble app keeps handling normal watch " +
            "features.",
        style = MaterialTheme.typography.bodyLarge,
    )
    Text(
        text = "Custom audio firmware on the watch is required.",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    if (showHow) {
        HorizontalDivider()
        Text(
            text = "How it works: your watch records microphone audio in the background and " +
                "streams it over Bluetooth to this app only. Audio is stored on this phone, " +
                "transcribed locally or in the cloud (your choice), and nothing leaves the " +
                "phone without your explicit consent. The watch shows its recording state and " +
                "asks for your confirmation before any app can receive audio.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    Button(onClick = onNext) { Text("Set Up Audio") }
    if (!showHow) {
        TextButton(onClick = { showHow = true }) { Text("Learn How It Works") }
    }
}

@Composable
private fun RequirementChecklistRow(text: String, detail: String) {
    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        Text(text = "• $text", style = MaterialTheme.typography.bodyLarge)
        Text(
            text = detail,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun RequirementsStep(onBack: () -> Unit, onNext: () -> Unit) {
    Text(
        text = "The app cannot verify all of these automatically — make sure they are true " +
            "before continuing:",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    RequirementChecklistRow(
        "Custom audio firmware installed on the watch",
        "Built from PebbleOS with the Audio Companion service enabled.",
    )
    RequirementChecklistRow(
        "Official Pebble app installed and paired",
        "It keeps handling notifications, apps, and firmware updates.",
    )
    RequirementChecklistRow("Bluetooth enabled", "On this phone.")
    RequirementChecklistRow("Watch nearby and charged", "Within Bluetooth range.")
    StepButtons(onBack = onBack, onNext = onNext)
}

@Composable
private fun PermissionsStep(onRequest: () -> Unit, onBack: () -> Unit, onNext: () -> Unit) {
    Text(
        text = "We use Bluetooth to receive audio from your watch, and notifications to show " +
            "receiver status and delivery problems. This app never uses the phone microphone.",
        style = MaterialTheme.typography.bodyLarge,
    )
    Button(onClick = onRequest) { Text("Grant Permissions") }
    StepButtons(onBack = onBack, onNext = onNext)
}

@Composable
private fun FindWatchStep(
    sessionState: ReceiverSessionState,
    onFind: () -> Unit,
    onBack: () -> Unit,
    onNext: () -> Unit,
) {
    Text(
        text = "Connect to the watch that will send audio to this app.",
        style = MaterialTheme.typography.bodyLarge,
    )
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StatusDot(
            when (sessionState) {
                ReceiverSessionState.Disconnected -> StatusSeverity.Neutral
                is ReceiverSessionState.ConnectionFailed -> StatusSeverity.Warning
                is ReceiverSessionState.Denied, is ReceiverSessionState.Revoked -> StatusSeverity.Warning
                else -> StatusSeverity.Info
            },
        )
        Text(
            text = when (sessionState) {
                ReceiverSessionState.Disconnected -> "Not connected"
                is ReceiverSessionState.ConnectionFailed -> "Connection failed: ${sessionState.message}"
                ReceiverSessionState.Connecting -> "Looking for your Pebble…"
                else -> "Watch found"
            },
            style = MaterialTheme.typography.bodyMedium,
        )
    }
    Button(onClick = onFind) { Text("Find My Watch") }
    if (sessionState == ReceiverSessionState.Disconnected ||
        sessionState is ReceiverSessionState.ConnectionFailed
    ) {
        Text(
            text = "Make sure the watch is nearby, Bluetooth is on, and custom audio firmware " +
                "is installed.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    StepButtons(onBack = onBack, onNext = onNext)
}

@Composable
private fun WatchConsentStep(
    sessionState: ReceiverSessionState,
    onRetry: () -> Unit,
    onBack: () -> Unit,
    onNext: () -> Unit,
) {
    Text(
        text = "Your watch will ask whether Pebble Audio Companion can receive microphone " +
            "audio in the background.",
        style = MaterialTheme.typography.bodyLarge,
    )
    val (severity, statusText) = when (sessionState) {
        ReceiverSessionState.PendingConsent ->
            StatusSeverity.Info to "Waiting — confirm on your watch now"
        ReceiverSessionState.PendingEnable ->
            StatusSeverity.Info to "Waiting — approve Background Audio on your watch"
        ReceiverSessionState.Authorized, is ReceiverSessionState.Streaming ->
            StatusSeverity.Active to "Authorized"
        is ReceiverSessionState.Denied -> when (sessionState.status) {
            AuthStatus.DeniedMismatch -> StatusSeverity.Warning to
                "This watch is already authorized for another receiver. Use Forget Receiver " +
                "in the watch's Audio Companion settings, then try again."
            AuthStatus.DeniedDisabled -> StatusSeverity.Warning to
                "Background Audio is off on the watch. Try again and approve the watch prompt."
            else -> StatusSeverity.Warning to "Not authorized"
        }
        is ReceiverSessionState.Revoked -> StatusSeverity.Warning to "Access was revoked"
        is ReceiverSessionState.ConnectionFailed ->
            StatusSeverity.Warning to "Connection failed: ${sessionState.message}"
        ReceiverSessionState.Disconnected -> StatusSeverity.Neutral to "Watch not connected"
        else -> StatusSeverity.Info to "Connecting…"
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StatusDot(severity)
        Text(text = statusText, style = MaterialTheme.typography.bodyMedium)
    }
    if (sessionState is ReceiverSessionState.Denied || sessionState is ReceiverSessionState.Revoked) {
        OutlinedButton(onClick = onRetry) { Text("Try Again") }
    }
    val authorized = sessionState == ReceiverSessionState.Authorized ||
        sessionState is ReceiverSessionState.Streaming
    StepButtons(
        onBack = onBack,
        onNext = onNext,
        nextLabel = if (authorized) "Continue" else "Skip For Now",
    )
}

@Composable
private fun PrivacyDefaultsStep(
    settings: AudioCompanionSettings,
    localModel: LocalTranscriptionModelState,
    actions: AppActions,
    onBack: () -> Unit,
    onNext: () -> Unit,
) {
    Text(
        text = "Choose your defaults. Local only keeps transcription on this phone; the other " +
            "transcription modes use the selected cloud provider when needed. You can change " +
            "this later in Settings.",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    InfoRow("Keep audio", "${settings.retentionDays} days")
    InfoRow("Transcription", transcriptionModeLabel(settings.transcriptionMode))
    InfoRow("AI", aiModeLabel(settings.aiMode))
    InfoRow(
        "Local model",
        when {
            localModel.installing -> "Installing..."
            localModel.downloading -> "Downloading..."
            localModel.downloaded -> "Installed"
            else -> "Not installed"
        },
    )
    localModel.selectedOption?.model?.let { model ->
        Text(
            text = "${model.displayName} (${Formatting.storageSize(model.downloadBytes)})",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    transcriptionSetupMessage(settings, localModel)?.let { message ->
        Text(
            text = message,
            style = MaterialTheme.typography.bodySmall,
            color = StatusColors.warning,
        )
    }
    if (localModel.downloading) {
        if (localModel.totalBytes > 0) {
            LinearProgressIndicator(
                progress = {
                    (localModel.downloadedBytes.toFloat() / localModel.totalBytes)
                        .coerceIn(0f, 1f)
                },
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                text = "${Formatting.storageSize(localModel.downloadedBytes)} of " +
                    Formatting.storageSize(localModel.totalBytes),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
    }
    localModel.errorMessage?.let {
        Text(text = it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (localModel.downloading) {
            OutlinedButton(onClick = actions.cancelModelDownload) { Text("Cancel download") }
        } else {
            OutlinedButton(onClick = actions.refreshLocalModel) { Text("Check model") }
            Button(
                enabled = !localModel.downloaded,
                onClick = actions.downloadLocalModel,
            ) {
                Text(if (localModel.downloaded) "Installed" else "Download model")
            }
        }
    }
    Text(
        text = "You are responsible for following recording and consent laws where you use " +
            "this feature.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    StepButtons(onBack = onBack, onNext = onNext)
}

@Composable
private fun ReadyStep(
    sessionState: ReceiverSessionState,
    settings: AudioCompanionSettings,
    onStart: () -> Unit,
    onDone: () -> Unit,
) {
    val authorized = sessionState == ReceiverSessionState.Authorized ||
        sessionState is ReceiverSessionState.Streaming
    Text(
        text = when {
            sessionState is ReceiverSessionState.Streaming -> "Recording from Pebble."
            authorized -> "Your watch is authorized. Start when you want background audio."
            else -> "Setup is done. You can finish authorizing your watch any time from " +
                "Settings, then start recording."
        },
        style = MaterialTheme.typography.bodyLarge,
    )
    if (!settings.backgroundReceiverEnabled && authorized) {
        Button(onClick = onStart) { Text("Start Recording") }
        TextButton(onClick = onDone) { Text("Not Now") }
    } else {
        Button(onClick = onDone) { Text("Done") }
    }
}
