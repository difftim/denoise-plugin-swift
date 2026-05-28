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
/// ## Single-tap (legacy) usage
///
/// ```swift
/// let pipeline = OfflineAudioPipeline(
///     initialModule: .deepfilternet,
///     soundTouchConfig: SoundTouchConfig(enabled: true, pitchSemiTones: 4)
/// )
///
/// while recording {
///     let pcm: [Float] = readPcmChunkFromAVAudioEngine()
///     let processed = pipeline.process(pcm)
///     encoder.write(processed)
/// }
///
/// let tail = pipeline.flush()
/// if !tail.isEmpty { encoder.write(tail) }
/// pipeline.release()
/// ```
///
/// ## Multi-tap usage (mirrors chative-desktop / TempTalk-Android)
///
/// ```swift
/// let pipeline = OfflineAudioPipeline(
///     taps: [
///         (id: "denoised",        config: PipelineTapConfig(denoise: true)),
///         (id: "denoised+higher", config: PipelineTapConfig(
///             denoise: true,
///             soundTouch: SoundTouchConfig.presets["goddess"]
///         )),
///     ],
///     initialModule: .deepfilternet
/// )
///
/// while recording {
///     let pcm = readPcmChunkFromAVAudioEngine()
///     let outs = pipeline.processTaps(pcm) // [String: [Float]]
///     if let d = outs["denoised"],         !d.isEmpty { denoisedEncoder.write(d) }
///     if let p = outs["denoised+higher"],  !p.isEmpty { processedEncoder.write(p) }
/// }
///
/// let tails = pipeline.flushTaps()
/// if let d = tails["denoised"],        !d.isEmpty { denoisedEncoder.write(d) }
/// if let p = tails["denoised+higher"], !p.isEmpty { processedEncoder.write(p) }
/// pipeline.release()
/// ```
///
/// Denoise inference runs once per chunk regardless of how many taps consume
/// the denoised PCM. Each tap with `soundTouch` gets its own pitch shifter.
public final class OfflineAudioPipeline {
    private let core: AudioPipelineCore

    /// Single-tap (legacy) initializer. Builds a one-tap pipeline whose
    /// denoise + voice-changer config is controlled by ``denoiseEnabled`` and
    /// ``soundTouchConfig``.
    ///
    /// Use the multi-tap initializer (the `taps:` overload) when you need
    /// multiple parallel candidates that share a single denoise inference.
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

    /// Multi-tap initializer. One shared denoise context fans out into N
    /// parallel taps, each with its own optional SoundTouch chain.
    ///
    /// The order of `taps` is preserved (the parameter is an array of tuples
    /// rather than a `Dictionary` precisely so iteration order matches what
    /// the caller declared).
    public init(
        taps: [(id: String, config: PipelineTapConfig)],
        initialModule: AudioModule = .rnnoise,
        deepFilterConfig: DeepFilterConfig = .init()
    ) {
        self.core = AudioPipelineCore(
            taps: taps,
            initialModule: initialModule,
            deepFilterConfig: deepFilterConfig
        )
    }

    /// Currently active denoise backend.
    public var activeModule: AudioModule { core.currentModule }

    /// Frame length (samples) of the currently active denoise backend.
    public var frameLength: Int { core.currentFrameLength }

    /// `true` when constructed via the multi-tap initializer.
    /// ``process(_:)`` / ``flush()`` trap in this mode.
    public var isMultiTap: Bool { core.isMultiTap }

    /// Tap ids in the order they were declared (single-tap mode = `["default"]`).
    public var tapIds: [String] { core.tapIds }

    /// `true` if any tap consumes denoise.
    public var denoiseEnabled: Bool { core.isDenoiseEnabled }

    /// `true` if any tap runs SoundTouch.
    public var voiceChangerEnabled: Bool { core.isVoiceChangerEnabled }

    // MARK: - Single-tap legacy API

    /// Single-output process. Traps in multi-tap mode — use
    /// ``processTaps(_:)`` instead.
    ///
    /// Returns a freshly allocated `[Float]` whose length is always a
    /// multiple of ``frameLength``. Sub-frame residuals are buffered
    /// internally and emitted on the next call (or by ``flush()``).
    public func process(_ input: [Float]) -> [Float] {
        return core.process(input)
    }

    /// Single-output flush. Traps in multi-tap mode — use ``flushTaps()``
    /// instead.
    ///
    /// Returns the sub-frame remainder from the input ring buffer
    /// (zero-padded for processing, then trimmed back to the real sample
    /// count) so total output sample count matches total input sample count.
    public func flush() -> [Float] {
        return core.flush()
    }

    // MARK: - Multi-tap API

    /// Multi-output process. Returns one `[Float]` per tap, keyed by the id
    /// the caller registered. In legacy single-tap mode this returns a
    /// one-entry map keyed by `"default"`.
    ///
    /// Denoise inference runs at most once per chunk regardless of how many
    /// taps consume the denoised PCM. Each tap with SoundTouch has its own
    /// stateful pitch shifter.
    public func processTaps(_ input: [Float]) -> [String: [Float]] {
        return core.processTaps(input)
    }

    /// Multi-output flush. Per-tap analog of ``flush()``; same caveats.
    public func flushTaps() -> [String: [Float]] {
        return core.flushTaps()
    }

    // MARK: - Lifecycle / configuration

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

    /// Legacy single-tap only. Traps in multi-tap mode.
    public func setDenoiseEnabled(_ enabled: Bool) {
        core.setDenoiseEnabled(enabled)
    }

    /// Legacy single-tap only. Traps in multi-tap mode.
    public func setSoundTouchConfig(_ config: SoundTouchConfig) {
        core.setSoundTouchConfig(config)
    }

    /// Legacy single-tap convenience: apply a named preset
    /// (`loli` / `uncle` / `goddess` / `monster` / `original`).
    public func setSoundTouchPreset(_ preset: String) {
        let config = SoundTouchConfig.presets[preset] ?? SoundTouchConfig(enabled: true, pitchSemiTones: 0)
        setSoundTouchConfig(config)
    }

    public func updateDeepFilterConfig(_ config: DeepFilterConfig) {
        core.updateDeepFilterConfig(config)
    }
}
