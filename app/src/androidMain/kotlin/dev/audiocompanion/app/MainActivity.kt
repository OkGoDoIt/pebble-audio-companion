package dev.audiocompanion.app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.companion.AssociationInfo
import android.companion.CompanionDeviceManager
import android.content.Intent
import android.content.IntentSender
import android.os.Build
import android.os.Bundle
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import dev.audiocompanion.adapter.ble.AndroidAudioCompanionAssociator
import dev.audiocompanion.adapter.ble.AndroidAudioGattLink
import dev.audiocompanion.adapter.ble.AudioCompanionBleService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val runtimeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var link: AndroidAudioGattLink
    private lateinit var runtime: AudioCompanionRuntime
    private lateinit var associator: AndroidAudioCompanionAssociator
    private lateinit var settingsRepository: AndroidAudioCompanionSettingsRepository
    private var lastSupportReport: AudioCompanionSupportReport? = null

    private val associationLauncher = registerForActivityResult(
        ActivityResultContracts.StartIntentSenderForResult(),
    ) { result ->
        val device = result.data?.extractBluetoothDevice()
        if (device != null) {
            startReceiver(device)
        } else {
            runtime.refreshDiagnostics()
        }
    }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) {
        associateWatch()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        link = AndroidAudioGattLink(this)
        runtime = AndroidAudioCompanionRuntimeFactory(this).create(link)
        associator = AndroidAudioCompanionAssociator(this)
        settingsRepository = AndroidAudioCompanionSettingsRepository(this)
        runtime.recoverDurableState()
        setContent {
            App(
                sessionState = runtime.state,
                diagnostics = runtime.diagnostics,
                settings = settingsRepository.settings,
                onPairWatch = { requestPermissionsAndAssociate() },
                onStartReceiver = { runtime.start(runtimeScope) },
                onStopReceiver = {
                    link.disconnect()
                    runtime.stop()
                },
                onRefreshDiagnostics = { runtime.refreshDiagnostics() },
                onBackgroundReceiverChanged = { enabled ->
                    settingsRepository.setBackgroundReceiverEnabled(enabled)
                    if (enabled) runtime.start(runtimeScope) else {
                        link.disconnect()
                        runtime.stop()
                    }
                },
                onCloudTranscriptionConsentChanged = settingsRepository::setCloudTranscriptionConsent,
                onRemoteAiConsentChanged = settingsRepository::setRemoteAiConsent,
                onDiagnosticsContentChanged = settingsRepository::setDiagnosticsIncludeContent,
                onCycleTranscriptionMode = {
                    settingsRepository.setTranscriptionMode(settingsRepository.settings.value.transcriptionMode.next())
                },
                onCycleAiMode = {
                    settingsRepository.setAiMode(settingsRepository.settings.value.aiMode.next())
                },
                onRetentionDaysChanged = settingsRepository::setRetentionDays,
                onDeleteAll = {
                    runtimeScope.launch {
                        link.disconnect()
                        runtime.deleteAllLocalData()
                    }
                },
                onExportDiagnostics = {
                    lastSupportReport = runtime.buildSupportReport(
                        includeContent = settingsRepository.settings.value.diagnosticsIncludeContent,
                    )
                },
                onRevokeReceiver = {
                    runtimeScope.launch {
                        link.disconnect()
                        runtime.revokeReceiverLocally()
                    }
                },
            )
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        runtimeScope.cancel()
    }

    private fun requestPermissionsAndAssociate() {
        val permissions = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_CONNECT)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (permissions.isEmpty()) {
            associateWatch()
        } else {
            permissionLauncher.launch(permissions.toTypedArray())
        }
    }

    private fun associateWatch() {
        associator.associate(
            object : AndroidAudioCompanionAssociator.Callback {
                override fun onAssociationPending(intentSender: IntentSender) {
                    associationLauncher.launch(IntentSenderRequest.Builder(intentSender).build())
                }

                override fun onAssociated(association: AssociationInfo) {
                    val device = association.deviceMacAddress?.toString()
                        ?.let { bluetoothAdapter()?.getRemoteDevice(it) }
                    if (device != null) {
                        startReceiver(device)
                    } else {
                        runtime.refreshDiagnostics()
                    }
                }

                override fun onFailure(message: CharSequence?) {
                    runtime.refreshDiagnostics()
                }
            },
        )
    }

    private fun startReceiver(device: BluetoothDevice) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(AudioCompanionBleService.startIntent(this))
        } else {
            startService(AudioCompanionBleService.startIntent(this))
        }
        runtime.start(runtimeScope)
        link.connect(device)
    }

    @Suppress("DEPRECATION")
    private fun Intent.extractBluetoothDevice(): BluetoothDevice? {
        getParcelableExtra<BluetoothDevice>(CompanionDeviceManager.EXTRA_DEVICE)?.let { return it }
        val association = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(CompanionDeviceManager.EXTRA_ASSOCIATION, AssociationInfo::class.java)
        } else {
            getParcelableExtra(CompanionDeviceManager.EXTRA_ASSOCIATION)
        }
        return association?.deviceMacAddress?.toString()
            ?.let { bluetoothAdapter()?.getRemoteDevice(it) }
    }

    private fun bluetoothAdapter(): BluetoothAdapter? =
        getSystemService(BluetoothManager::class.java)?.adapter
}
