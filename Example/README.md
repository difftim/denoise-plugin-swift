# iOS SDK demo: voice-message dual-candidate recorder

`VoiceMsgDemoViewController.swift` is a single-file reference UIKit view
controller that validates the SDK's `OfflineAudioPipeline` end-to-end:

- Captures one mic stream via `AVAudioEngine`, resampled to 48 kHz mono
  float32.
- Writes the PCM into two AAC m4a files in parallel:
  - `original-<ts>.m4a` — raw passthrough, never touches the SDK.
  - `processed-<ts>.m4a` — same PCM run through `OfflineAudioPipeline`
    (RNNoise denoise + optional voice changer at +4 semitones).
- Buttons: Start / Stop / Cancel / Play original / Play processed.

This screen lives in the SDK repo on purpose — product apps (TempTalk-iOS
etc.) should mirror this integration pattern when they want the dual-
candidate voice-message flow.

## Why this is "drag-into-Xcode" rather than runnable

`AudioPipelineProcessor` depends on `LiveKit`, which transitively depends
on the `LiveKitWebRTC` binary xcframework. That xcframework only ships
`iOS` and `iOS-Simulator` slices today (no `macOS`), so a self-contained
`swift run` executable target cannot build the demo. The demo therefore
ships as one source file you drop into any iOS Xcode app.

## Setup (≈ 2 minutes)

1. **Create a fresh iOS app target** in Xcode (App template, UIKit
   lifecycle, Swift). Or pick any existing iOS app of yours.

2. **Add the SDK as a Swift Package dependency**.
   - File → Add Package Dependencies → Search field paste:
     `https://github.com/difftim/denoise-plugin-swift` (or the local path
     to this `denoise-plugin-swift/` folder while developing on
     branch `feat/offline-audio-pipeline`).
   - Pick the `AudioPipelineProcessor` library.

3. **Drag `VoiceMsgDemoViewController.swift` into your app's source group**.
   Make sure it is added to the app target's "Compile Sources".

4. **Wire it into your app's window**. Easiest path — replace the default
   ViewController in `SceneDelegate.swift` (or `AppDelegate.swift` for
   non-scene apps):

   ```swift
   func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
              options connectionOptions: UIScene.ConnectionOptions) {
       guard let windowScene = (scene as? UIWindowScene) else { return }
       let window = UIWindow(windowScene: windowScene)
       let nav = UINavigationController(
           rootViewController: VoiceMsgDemoViewController()
       )
       window.rootViewController = nav
       self.window = window
       window.makeKeyAndVisible()
   }
   ```

5. **Add `NSMicrophoneUsageDescription`** to `Info.plist` (any string is
   fine, e.g. "Voice message demo records mic input").

6. **Run on a real device** (the iOS simulator doesn't expose a working
   mic on most machines). Recording outputs go to
   `<NSTemporaryDirectory>/voice-msg-demo/`; they can be read back via the
   in-app Play buttons.

## Validating offline / file-based usage

If you don't have a host iOS app handy, you can still validate the SDK
file-by-file by writing a tiny unit test inside any project that has the
SDK SPM dep:

```swift
import AudioPipelineProcessor

let pipeline = OfflineAudioPipeline(initialModule: .rnnoise)
let silence = [Float](repeating: 0, count: 480 * 10)
let out = pipeline.process(silence)
assert(out.count == silence.count)
pipeline.release()
```

That exercises the same code path the demo VC uses, without needing mic
permission.

## Known limitations

- `flush()` currently returns an empty array — the SoundTouch C bridge in
  `AudioPipeline.xcframework` does not yet expose a drain entry point. The
  demo wires the call anyway so the tail will appear automatically once
  the native interface lands.
- The demo does not configure `AVAudioSession`. If the host app is in a
  call or another audio session is active, `engine.start()` may fail. A
  production wiring should reuse the host app's audio session helper.
- The demo uses AAC m4a for both files at identical 48 kHz mono settings
  so they're byte-comparable for duration / size. Real product apps with
  different codec needs (Opus, MP3, etc.) should plug their preferred
  encoder in place of `AVAudioFile`.
