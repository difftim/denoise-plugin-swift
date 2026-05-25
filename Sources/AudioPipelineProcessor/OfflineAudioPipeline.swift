import Foundation

/// PCM-in / PCM-out audio pipeline for **offline / non-LiveKit** scenarios
/// (voice messages, file processing, local PCM streams).
///
/// - Input / output: 48 kHz mono normalized float32 PCM (`[-1.0, 1.0]`),
///   matching `AVAudioPCMBuffer` in `.pcmFormatFloat32`.
/// - Threading: not thread-safe; callers must externally serialise access
///   from the recording / encoding thread.
/// - Instance isolation: each `OfflineAudioPipeline` owns its own RNNoise /
///   DeepFilterNet / SoundTouch native contexts; `reset()` / `flush()` /
///   `release()` on this instance never affect any other instance (including
///   any ``AudioPipelineProcessor`` running in the same process for LiveKit).
///
/// Typical usage:
///
/// ```swift
/// let pipeline = OfflineAudioPipeline(
///     initialModule: .deepfilternet,
///     soundTouchConfig: SoundTouchConfig(enabled: true, pitchSemiTones: 4)
/// )
///
/// // In AVAudioInputNode tap callback:
/// let processed = pipeline.process(pcmFloats)
/// // Write processed to AVAssetWriter / AVAudioFile
///
/// // Stop recording:
/// let tail = pipeline.flush()
/// if !tail.isEmpty { writer.write(tail) }
/// pipeline.release()
/// ```
public final class OfflineAudioPipeline {
    private let core: AudioPipelineCore

    public init(
        initialModule: AudioModule = .rnnoise,
        deepFilterConfig: DeepFilterConfig = .init(),
        soundTouchConfig: SoundTouchConfig = .init(),
        denoiseEnabled: Bool = true
    ) {
        self.core = AudioPipelineCore(
            initialModule: initialModule,
            deepFilterConfig: deepFilterConfig,
            soundTouchConfig: soundTouchConfig,
            denoiseEnabled: denoiseEnabled
        )
    }

    /// Currently active denoise backend.
    public var activeModule: AudioModule { core.currentModule }

    /// Frame length (samples) of the currently active denoise backend.
    public var frameLength: Int { core.currentFrameLength }

    public var denoiseEnabled: Bool { core.isDenoiseEnabled }
    public var voiceChangerEnabled: Bool { core.isVoiceChangerEnabled }

    /// Process a chunk of 48 kHz mono normalized float32 PCM.
    ///
    /// Returns processed PCM whose length is always a multiple of
    /// ``frameLength``. Sub-frame residuals are buffered internally and
    /// emitted on the next call (or by ``flush()``).
    public func process(_ input: [Float]) -> [Float] {
        return core.process(input)
    }

    /// Drain any residual tail PCM held inside stateful processors. For
    /// pure-denoise pipelines this always returns an empty array.
    ///
    /// The current SDK ships without a SoundTouch drain entry point in the
    /// native bridge, so this returns an empty array today. The signature is
    /// stable — wiring `flush()` into the recording stop flow now means tail
    /// PCM starts to appear automatically once the native interface lands.
    public func flush() -> [Float] {
        return core.flush()
    }

    /// Clear internal state. Instance stays usable.
    public func reset() {
        core.reset()
    }

    /// Release all native resources. Instance becomes unusable.
    public func release() {
        core.release()
    }

    public func setModule(_ module: AudioModule) {
        core.setModule(module)
    }

    public func setDenoiseEnabled(_ enabled: Bool) {
        core.setDenoiseEnabled(enabled)
    }

    public func setSoundTouchConfig(_ config: SoundTouchConfig) {
        core.setSoundTouchConfig(config)
    }

    /// Convenience: apply a named preset (`loli` / `uncle` / `goddess` /
    /// `monster` / `original`).
    public func setSoundTouchPreset(_ preset: String) {
        let config = SoundTouchConfig.presets[preset] ?? SoundTouchConfig(enabled: true, pitchSemiTones: 0)
        setSoundTouchConfig(config)
    }

    public func updateDeepFilterConfig(_ config: DeepFilterConfig) {
        core.updateDeepFilterConfig(config)
    }
}
