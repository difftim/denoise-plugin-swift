# VoiceMsgDemoApp

Minimal iOS app wrapper for `Example/VoiceMsgDemoViewController.swift`.

## Open

```bash
open denoise-plugin-swift/Example/VoiceMsgDemoApp/VoiceMsgDemoApp.xcodeproj
```

The project depends on the local Swift package at `denoise-plugin-swift/` and
links the `AudioPipelineProcessor` product.

## Run

1. Select the `VoiceMsgDemoApp` scheme.
2. Select an iOS device or simulator.
3. If running on device, set a development team in Signing & Capabilities.
4. Press Run.

The app requests microphone permission and launches directly into
`VoiceMsgDemoViewController`.
