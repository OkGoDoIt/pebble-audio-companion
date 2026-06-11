# iOS BLE Adapter

`IosAudioGattLink` is the Core Bluetooth implementation of the Audio Companion receiver link.
It is intentionally limited to BLE session duties: restoration, service discovery, notification
subscription, Info reads, Control writes, and forwarding whole Control/Data notifications into the
shared `AudioGattLink` flows.

The host iOS app must include:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

The central manager is created with restore identifier `audio-companion-central`. The app should
instantiate the link at launch, recover durable storage before starting `AudioReceiverSession`, and
keep Core Bluetooth callbacks fast: append bytes to the receiver pipeline and return. Transcription,
AI processing, upload, and retention work must run from durable storage outside the BLE callback.
