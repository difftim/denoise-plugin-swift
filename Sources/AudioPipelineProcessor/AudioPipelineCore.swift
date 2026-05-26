import AudioPipeline
import Foundation

/// Pure PCM-in / PCM-out processing core. Wraps RNNoise / DeepFilterNet /
/// SoundTouch and applies the fixed pipeline order: denoise -> soundtouch.
///
/// Each instance owns its own native contexts (RNNoise, DeepFilterNet,
/// SoundTouch) and input ring buffer. Calling `reset()` / `flush()` /
/// `release()` on this instance NEVER touches any other instance — including
/// any ``AudioPipelineProcessor`` running in the same process for LiveKit.
///
/// Threading: not thread-safe. Callers must externally serialise access from
/// the recording / encoding thread.
internal final class AudioPipelineCore {
    private static let rnnoiseFrameSize = 480
    private static let ringCapacityFrames = 128

    private var rnnoiseWrapper: RNNoiseWrapper?
    private var dfContext: OpaquePointer?
    private var stContext: OpaquePointer?

    private var dfFrameLength: Int = 0
    private var dfInputBuffer: [Float] = []
    private var dfOutputBuffer: [Float] = []

    private var activeModule: AudioModule
    private var denoiseEnabled: Bool
    private var deepFilterConfig: DeepFilterConfig
    private var soundTouchConfig: SoundTouchConfig

    private var frameLength: Int = AudioPipelineCore.rnnoiseFrameSize
    private var inputRing: FloatRingBuffer = FloatRingBuffer(
        capacity: AudioPipelineCore.rnnoiseFrameSize * AudioPipelineCore.ringCapacityFrames
    )
    private var frameScratch: [Float] = [Float](repeating: 0, count: AudioPipelineCore.rnnoiseFrameSize)

    private var released = false

    init(
        initialModule: AudioModule = .rnnoise,
        deepFilterConfig: DeepFilterConfig = .init(),
        soundTouchConfig: SoundTouchConfig = .init(),
        denoiseEnabled: Bool = true
    ) {
        self.activeModule = initialModule
        self.denoiseEnabled = denoiseEnabled
        self.deepFilterConfig = deepFilterConfig
        self.soundTouchConfig = soundTouchConfig

        if initialModule == .deepfilternet {
            ensureDeepFilter()
            switchFrameLength(dfFrameLength)
        } else {
            ensureRnnoise()
        }

        if soundTouchConfig.enabled {
            ensureSoundTouch()
        }
    }

    deinit {
        release()
    }

    var currentModule: AudioModule { activeModule }
    var currentFrameLength: Int { frameLength }
    var isDenoiseEnabled: Bool { denoiseEnabled }
    var isVoiceChangerEnabled: Bool { soundTouchConfig.enabled }

    /// Process a chunk of 48 kHz mono normalized float32 PCM in `[-1, 1]`.
    /// Returns processed PCM whose length is always a multiple of
    /// ``currentFrameLength``. Sub-frame residuals are buffered and emitted
    /// on the next call (or by ``flush()``).
    func process(_ input: [Float]) -> [Float] {
        precondition(!released, "AudioPipelineCore: instance has been released")
        guard !input.isEmpty else { return [] }

        ensureRingCapacity(for: input.count)
        inputRing.push(input)

        let frameLen = frameLength
        guard frameLen > 0, inputRing.framesAvailable >= frameLen else {
            return []
        }

        let frameCount = inputRing.framesAvailable / frameLen
        var out = [Float](repeating: 0, count: frameCount * frameLen)

        out.withUnsafeMutableBufferPointer { outPtr in
            for i in 0..<frameCount {
                _ = inputRing.pull(into: &frameScratch)

                if denoiseEnabled {
                    switch activeModule {
                    case .rnnoise:
                        if let wrapper = rnnoiseWrapper {
                            applyRnnoise(wrapper: wrapper, frame: &frameScratch)
                        }
                    case .deepfilternet:
                        if let ctx = dfContext, dfFrameLength == frameLen {
                            applyDeepFilter(ctx: ctx, frame: &frameScratch)
                        }
                    }
                }

                if soundTouchConfig.enabled, let ctx = stContext {
                    applySoundTouch(ctx: ctx, frame: &frameScratch)
                }

                let dst = outPtr.baseAddress!.advanced(by: i * frameLen)
                frameScratch.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: frameLen)
                }
            }
        }

        return out
    }

    /// Drain residual PCM held inside the pipeline.
    ///
    /// Pulls whatever the input ring buffer has accumulated since the last
    /// frame-aligned `process()` call (typically < 1 RNNoise frame =
    /// ≤ 10 ms), pads it to a full frame with zeros, runs it through
    /// denoise + voice changer, and returns only the slice of samples that
    /// correspond to actual mic input. The zero padding never appears in
    /// the returned array, so the **total output sample count is identical
    /// to the total input sample count** when `process()` and `flush()`
    /// are called as a pair.
    ///
    /// Voice changer note: SoundTouch keeps an internal ~40–50 ms FIFO
    /// (SETTING_SEQUENCE_MS=40, OVERLAP_MS=8) that always lags its input
    /// by that algorithmic delay. The current `st_process_frame` wrapper
    /// preserves byte-perfect length by passing samples through unmodified
    /// whenever SoundTouch hasn't produced a full frame yet. The trade-off
    /// is informational, not numerical: the first ~50 ms of output is
    /// unprocessed passthrough (warmup), and the last ~50 ms of the
    /// recording's processed form stays in SoundTouch's FIFO and is NOT
    /// emitted at flush time. Sample counts still match exactly.
    func flush() -> [Float] {
        precondition(!released, "AudioPipelineCore: instance has been released")
        let remaining = inputRing.framesAvailable
        let frameLen = frameLength
        if remaining == 0 || frameLen == 0 { return [] }

        var padded = [Float](repeating: 0, count: frameLen)
        var tail = [Float](repeating: 0, count: remaining)
        _ = inputRing.pull(into: &tail)
        for i in 0..<remaining { padded[i] = tail[i] }

        if denoiseEnabled {
            switch activeModule {
            case .rnnoise:
                if let wrapper = rnnoiseWrapper {
                    applyRnnoise(wrapper: wrapper, frame: &padded)
                }
            case .deepfilternet:
                if let ctx = dfContext, dfFrameLength == frameLen {
                    applyDeepFilter(ctx: ctx, frame: &padded)
                }
            }
        }

        if soundTouchConfig.enabled, let ctx = stContext {
            applySoundTouch(ctx: ctx, frame: &padded)
        }

        return Array(padded[0..<remaining])
    }

    /// Clear internal buffers and reset SoundTouch warmup state.
    func reset() {
        precondition(!released, "AudioPipelineCore: instance has been released")
        inputRing.clear()
        if let ctx = stContext {
            st_destroy(ctx)
            stContext = nil
            ensureSoundTouch()
        }
    }

    /// Release all native resources. Instance becomes unusable.
    func release() {
        if released { return }
        released = true
        rnnoiseWrapper = nil
        if let ctx = dfContext {
            df_free(ctx)
            dfContext = nil
            dfFrameLength = 0
            dfInputBuffer = []
            dfOutputBuffer = []
        }
        if let ctx = stContext {
            st_destroy(ctx)
            stContext = nil
        }
    }

    func setModule(_ module: AudioModule) {
        precondition(!released, "AudioPipelineCore: instance has been released")
        if module == activeModule { return }
        switch module {
        case .deepfilternet: ensureDeepFilter()
        case .rnnoise:       ensureRnnoise()
        }
        activeModule = module
        let nextLen: Int = (module == .deepfilternet) ? dfFrameLength : AudioPipelineCore.rnnoiseFrameSize
        if nextLen != frameLength {
            switchFrameLength(nextLen)
        }
    }

    func setDenoiseEnabled(_ enabled: Bool) {
        precondition(!released, "AudioPipelineCore: instance has been released")
        denoiseEnabled = enabled
    }

    func setSoundTouchConfig(_ config: SoundTouchConfig) {
        precondition(!released, "AudioPipelineCore: instance has been released")
        soundTouchConfig = config
        if config.enabled {
            ensureSoundTouch()
            if let ctx = stContext {
                st_set_pitch_semitones(ctx, config.pitchSemiTones)
            }
        } else if let ctx = stContext {
            st_destroy(ctx)
            stContext = nil
        }
    }

    func updateDeepFilterConfig(_ config: DeepFilterConfig) {
        precondition(!released, "AudioPipelineCore: instance has been released")
        deepFilterConfig = config
        if let ctx = dfContext {
            df_set_atten_lim(ctx, config.attenLimDb)
            df_set_post_filter_beta(ctx, config.postFilterBeta)
        }
    }

    // MARK: - Native helpers

    private static let int16ToFloat: Float = 1.0 / 32768.0
    private static let floatToInt16: Float = 32768.0

    private func applyRnnoise(wrapper: RNNoiseWrapper, frame: inout [Float]) {
        // RNNoise wrapper expects int16-scale floats: scale up, process, scale back.
        let count = frame.count
        for i in 0..<count { frame[i] *= Self.floatToInt16 }
        frame.withUnsafeMutableBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            _ = wrapper.processFrame(baseAddress, frameSize: Int32(count))
        }
        for i in 0..<count { frame[i] *= Self.int16ToFloat }
    }

    private func applyDeepFilter(ctx: OpaquePointer, frame: inout [Float]) {
        // DeepFilterNet takes [-1, 1] directly — no scaling.
        let count = frame.count
        for i in 0..<count { dfInputBuffer[i] = frame[i] }
        dfInputBuffer.withUnsafeMutableBufferPointer { inPtr in
            dfOutputBuffer.withUnsafeMutableBufferPointer { outPtr in
                _ = df_process_frame(ctx, inPtr.baseAddress, outPtr.baseAddress)
            }
        }
        for i in 0..<count { frame[i] = dfOutputBuffer[i] }
    }

    private func applySoundTouch(ctx: OpaquePointer, frame: inout [Float]) {
        // The C bridge expects int16-scale floats: scale up, run, scale back.
        // Warmup returns 0 and leaves the buffer unchanged at int16 scale, so
        // we always scale back regardless of the return value.
        let count = frame.count
        for i in 0..<count { frame[i] *= Self.floatToInt16 }
        frame.withUnsafeMutableBufferPointer { ptr in
            _ = st_process_frame(ctx, ptr.baseAddress, Int32(count))
        }
        for i in 0..<count { frame[i] *= Self.int16ToFloat }
    }

    // MARK: - Lifecycle helpers

    private func ensureRnnoise() {
        guard rnnoiseWrapper == nil else { return }
        let wrapper = RNNoiseWrapper()
        if wrapper.initialize(48000, numChannels: 1) {
            rnnoiseWrapper = wrapper
        }
    }

    private func ensureDeepFilter() {
        guard dfContext == nil else { return }
        let cfg = deepFilterConfig
        guard let ctx = df_create_default(
            cfg.attenLimDb,
            cfg.minDbThresh,
            cfg.maxDbErbThresh,
            cfg.maxDbDfThresh
        ) else {
            return
        }
        dfContext = ctx
        dfFrameLength = df_get_frame_length(ctx)
        if dfFrameLength > 0 {
            dfInputBuffer = [Float](repeating: 0, count: dfFrameLength)
            dfOutputBuffer = [Float](repeating: 0, count: dfFrameLength)
        }
        df_set_atten_lim(ctx, cfg.attenLimDb)
        df_set_post_filter_beta(ctx, cfg.postFilterBeta)
    }

    private func ensureSoundTouch() {
        guard stContext == nil else { return }
        guard let ctx = st_create(48000) else { return }
        stContext = ctx
        st_set_pitch_semitones(ctx, soundTouchConfig.pitchSemiTones)
    }

    private func switchFrameLength(_ newLength: Int) {
        if newLength <= 0 || newLength == frameLength { return }

        // Carry over any leftover residual.
        var carryover: [Float] = []
        if inputRing.framesAvailable > 0 {
            carryover = [Float](repeating: 0, count: inputRing.framesAvailable)
            _ = inputRing.pull(into: &carryover)
        }

        frameLength = newLength
        inputRing = FloatRingBuffer(capacity: newLength * Self.ringCapacityFrames)
        frameScratch = [Float](repeating: 0, count: newLength)
        if !carryover.isEmpty {
            inputRing.push(carryover)
        }
    }

    private func ensureRingCapacity(for incoming: Int) {
        let needed = inputRing.framesAvailable + incoming
        if needed <= inputRing.capacity { return }
        let newCap = max(inputRing.capacity * 2, needed + frameLength)
        var carryover: [Float] = []
        if inputRing.framesAvailable > 0 {
            carryover = [Float](repeating: 0, count: inputRing.framesAvailable)
            _ = inputRing.pull(into: &carryover)
        }
        inputRing = FloatRingBuffer(capacity: newCap)
        if !carryover.isEmpty {
            inputRing.push(carryover)
        }
    }
}
