import AudioPipeline
import Foundation

/// Pure PCM-in / PCM-out processing core.
///
/// **Single-output mode (legacy)**: one chain `[denoise?] -> [soundtouch?]`,
/// `process()` returns a `[Float]`.
///
/// **Multi-output mode**: a single shared denoise context fans out into one or
/// more taps, each with its own optional SoundTouch chain. Denoise inference
/// runs at most once per chunk regardless of how many taps consume it.
/// `processTaps()` returns a `[String: [Float]]` keyed by the same ids
/// the caller passed to `taps`.
///
/// Each instance owns its own RNNoise / DeepFilterNet / SoundTouch native
/// contexts and input ring buffer. Calling `reset()` / `flush()` / `release()`
/// on this instance NEVER touches any other instance — including any
/// ``AudioPipelineProcessor`` running in the same process for LiveKit.
///
/// Threading: not thread-safe. Callers must externally serialise access from
/// the recording / encoding thread.
internal final class AudioPipelineCore {
    private static let rnnoiseFrameSize = 480
    private static let ringCapacityFrames = 128
    static let legacyTapId = "default"

    /// Per-tap mutable state owned by the core.
    private final class TapState {
        let id: String
        var denoise: Bool
        var soundTouchConfig: SoundTouchConfig?
        var stContext: OpaquePointer?

        init(id: String, denoise: Bool, soundTouchConfig: SoundTouchConfig?) {
            self.id = id
            self.denoise = denoise
            self.soundTouchConfig = soundTouchConfig
            self.stContext = nil
        }
    }

    private var rnnoiseWrapper: RNNoiseWrapper?
    private var dfContext: OpaquePointer?

    private var dfFrameLength: Int = 0
    private var dfInputBuffer: [Float] = []
    private var dfOutputBuffer: [Float] = []

    private var activeModule: AudioModule
    private var deepFilterConfig: DeepFilterConfig

    private let tapList: [TapState]
    private let multiTap: Bool

    private var frameLength: Int = AudioPipelineCore.rnnoiseFrameSize
    private var inputRing: FloatRingBuffer = FloatRingBuffer(
        capacity: AudioPipelineCore.rnnoiseFrameSize * AudioPipelineCore.ringCapacityFrames
    )
    /// One mic frame pulled from the ring buffer per iteration.
    private var rawFrameScratch: [Float] = [Float](repeating: 0, count: AudioPipelineCore.rnnoiseFrameSize)
    /// Shared denoised frame, populated on demand inside each process loop.
    private var denoisedFrameScratch: [Float] = [Float](repeating: 0, count: AudioPipelineCore.rnnoiseFrameSize)
    /// Per-tap mutable scratch (SoundTouch processes in place).
    private var tapFrameScratch: [Float] = [Float](repeating: 0, count: AudioPipelineCore.rnnoiseFrameSize)

    private var released = false

    // MARK: - Init

    /// Legacy single-tap initializer. Builds a one-tap pipeline whose denoise
    /// flag and SoundTouch config match the old `process()`/`flush()` shape.
    init(
        initialModule: AudioModule = .rnnoise,
        deepFilterConfig: DeepFilterConfig = .init(),
        soundTouchConfig: SoundTouchConfig = .init(),
        denoiseEnabled: Bool = true
    ) {
        self.activeModule = initialModule
        self.deepFilterConfig = deepFilterConfig
        self.multiTap = false

        let legacyTap = TapState(
            id: AudioPipelineCore.legacyTapId,
            denoise: denoiseEnabled,
            soundTouchConfig: soundTouchConfig.enabled ? soundTouchConfig : nil
        )
        self.tapList = [legacyTap]
        bootstrapNativeContexts()
    }

    /// Multi-tap initializer. One shared denoise context, N output taps.
    /// `taps` ordering is preserved (use an array of `(id, config)` tuples
    /// because Swift `Dictionary` doesn't guarantee iteration order).
    init(
        taps: [(id: String, config: PipelineTapConfig)],
        initialModule: AudioModule = .rnnoise,
        deepFilterConfig: DeepFilterConfig = .init()
    ) {
        precondition(!taps.isEmpty, "AudioPipelineCore: taps must not be empty")
        // Tap ids must be unique — duplicate ids would collide in the output map.
        var seen: Set<String> = []
        for entry in taps {
            precondition(seen.insert(entry.id).inserted,
                         "AudioPipelineCore: duplicate tap id '\(entry.id)'")
        }

        self.activeModule = initialModule
        self.deepFilterConfig = deepFilterConfig
        self.multiTap = true

        self.tapList = taps.map { entry in
            TapState(
                id: entry.id,
                denoise: entry.config.denoise,
                soundTouchConfig: entry.config.soundTouch.flatMap { $0.enabled ? $0 : nil }
            )
        }
        bootstrapNativeContexts()
    }

    /// Allocate the native contexts the active configuration requires.
    ///
    /// Today none of the ``ensure*`` helpers throw — they log + leave the
    /// handle unset on failure — so this method has no fault path. The
    /// equivalent Kotlin code wraps an analogous block in try/catch to roll
    /// every per-tap SoundTouch context back on partial init failure; if/when
    /// we convert any of these to throwing variants (e.g. surfacing
    /// `df_create_default == nil` as a typed error), call
    /// ``destroyAllNativeContexts`` from a `catch` block here before
    /// rethrowing so the half-constructed instance can't leak ~16 MB of DFN
    /// state.
    private func bootstrapNativeContexts() {
        let anyDenoise = tapList.contains { $0.denoise }
        if anyDenoise {
            if activeModule == .deepfilternet {
                ensureDeepFilter()
                if dfFrameLength > 0 { switchFrameLength(dfFrameLength) }
            } else {
                ensureRnnoise()
            }
        }
        for tap in tapList {
            ensureSoundTouchForTap(tap)
        }
    }

    deinit {
        release()
    }

    var currentModule: AudioModule { activeModule }
    var currentFrameLength: Int { frameLength }
    /// True when the core was constructed via the multi-tap initializer.
    var isMultiTap: Bool { multiTap }
    /// Tap ids in declaration order (single-tap mode = `["default"]`).
    var tapIds: [String] { tapList.map { $0.id } }
    /// True if any tap consumes denoise.
    var isDenoiseEnabled: Bool { tapList.contains { $0.denoise } }
    /// True if any tap runs SoundTouch.
    var isVoiceChangerEnabled: Bool {
        tapList.contains { $0.soundTouchConfig?.enabled == true }
    }

    // MARK: - Single-tap legacy API

    /// Single-output process. Traps in multi-tap mode — use ``processTaps(_:)``.
    func process(_ input: [Float]) -> [Float] {
        assertSingleTap("process")
        return processTaps(input)[AudioPipelineCore.legacyTapId] ?? []
    }

    /// Single-output flush. Traps in multi-tap mode — use ``flushTaps()``.
    func flush() -> [Float] {
        assertSingleTap("flush")
        return flushTaps()[AudioPipelineCore.legacyTapId] ?? []
    }

    // MARK: - Multi-tap API

    /// Multi-output process. Returns one `[Float]` per tap, keyed by the id
    /// the caller registered. In legacy single-tap mode this returns a
    /// one-entry map keyed by ``legacyTapId``.
    ///
    /// Denoise inference runs at most once per chunk regardless of how many
    /// taps consume the denoised PCM. Each tap with SoundTouch has its own
    /// stateful pitch shifter.
    func processTaps(_ input: [Float]) -> [String: [Float]] {
        precondition(!released, "AudioPipelineCore: instance has been released")
        if input.isEmpty { return makeEmptyTapOutputs(perTapLength: 0) }

        ensureRingCapacity(for: input.count)
        inputRing.push(input)

        let frameLen = frameLength
        guard frameLen > 0, inputRing.framesAvailable >= frameLen else {
            return makeEmptyTapOutputs(perTapLength: 0)
        }

        let frameCount = inputRing.framesAvailable / frameLen
        var outputs = makeEmptyTapOutputs(perTapLength: frameCount * frameLen)

        for f in 0..<frameCount {
            _ = inputRing.pull(into: &rawFrameScratch)
            runFrameIntoTaps(writeOffset: f * frameLen, outputs: &outputs)
        }

        return outputs
    }

    /// Multi-output flush. Per-tap analog of ``flush()``; same caveats.
    ///
    /// Pulls whatever the input ring buffer has accumulated since the last
    /// frame-aligned ``processTaps(_:)`` call (typically < 1 backend frame =
    /// ≤ 10 ms), pads it to a full frame with zeros, runs it through every
    /// tap, and returns only the slice of samples that correspond to actual
    /// mic input. The zero padding never appears in returned arrays.
    ///
    /// Voice changer caveat: each SoundTouch instance keeps an internal
    /// ~40–50 ms FIFO (SETTING_SEQUENCE_MS=40, OVERLAP_MS=8) that always
    /// lags its input by that algorithmic delay. Sample counts still match
    /// exactly; only the "pitched tail of the recording" information is
    /// lost for taps that use SoundTouch.
    func flushTaps() -> [String: [Float]] {
        precondition(!released, "AudioPipelineCore: instance has been released")
        let remaining = inputRing.framesAvailable
        let frameLen = frameLength
        if remaining == 0 || frameLen == 0 { return makeEmptyTapOutputs(perTapLength: 0) }

        // Pull partial frame into the first `remaining` slots; trailing zeros.
        for i in 0..<frameLen { rawFrameScratch[i] = 0 }
        var tail = [Float](repeating: 0, count: remaining)
        _ = inputRing.pull(into: &tail)
        for i in 0..<remaining { rawFrameScratch[i] = tail[i] }

        var padded = makeEmptyTapOutputs(perTapLength: frameLen)
        runFrameIntoTaps(writeOffset: 0, outputs: &padded)

        // Trim each tap output back to the real sample count.
        var trimmed: [String: [Float]] = [:]
        trimmed.reserveCapacity(tapList.count)
        for tap in tapList {
            if let full = padded[tap.id] {
                trimmed[tap.id] = Array(full[0..<remaining])
            } else {
                trimmed[tap.id] = []
            }
        }
        return trimmed
    }

    // MARK: - Lifecycle / configuration

    /// Clear internal buffers and reset SoundTouch warmup state for every tap.
    func reset() {
        precondition(!released, "AudioPipelineCore: instance has been released")
        inputRing.clear()
        // RNNoise / DeepFilterNet are kept because their per-frame behaviour
        // does not depend on stream boundaries; SoundTouch's FIFO is rebuilt.
        for tap in tapList {
            if let ctx = tap.stContext, tap.soundTouchConfig != nil {
                st_destroy(ctx)
                tap.stContext = nil
                ensureSoundTouchForTap(tap)
            }
        }
    }

    /// Release all native resources. Instance becomes unusable.
    func release() {
        if released { return }
        released = true
        destroyAllNativeContexts()
    }

    /// Destroy every native context this instance currently holds.
    /// Idempotent — safe to call from both ``release`` and the constructor
    /// rollback path without double-freeing.
    private func destroyAllNativeContexts() {
        rnnoiseWrapper = nil
        if let ctx = dfContext {
            df_free(ctx)
            dfContext = nil
            dfFrameLength = 0
            dfInputBuffer = []
            dfOutputBuffer = []
        }
        for tap in tapList {
            if let ctx = tap.stContext {
                st_destroy(ctx)
                tap.stContext = nil
            }
        }
    }

    func setModule(_ module: AudioModule) {
        precondition(!released, "AudioPipelineCore: instance has been released")
        if module == activeModule { return }
        let anyDenoise = tapList.contains { $0.denoise }
        if anyDenoise {
            switch module {
            case .deepfilternet: ensureDeepFilter()
            case .rnnoise:       ensureRnnoise()
            }
        }
        activeModule = module
        let nextLen: Int = (module == .deepfilternet)
            ? (dfFrameLength > 0 ? dfFrameLength : AudioPipelineCore.rnnoiseFrameSize)
            : AudioPipelineCore.rnnoiseFrameSize
        if nextLen != frameLength {
            switchFrameLength(nextLen)
            // Rebuild each tap's SoundTouch to match the new frame length.
            for tap in tapList {
                if let ctx = tap.stContext, tap.soundTouchConfig != nil {
                    st_destroy(ctx)
                    tap.stContext = nil
                    ensureSoundTouchForTap(tap)
                }
            }
        }
    }

    /// Toggle denoise on/off in legacy single-tap mode. Traps in multi-tap
    /// mode (where each tap's denoise flag was fixed at construction time).
    func setDenoiseEnabled(_ enabled: Bool) {
        precondition(!released, "AudioPipelineCore: instance has been released")
        assertSingleTap("setDenoiseEnabled")
        tapList[0].denoise = enabled
    }

    /// Legacy single-tap SoundTouch config setter. Traps in multi-tap mode.
    func setSoundTouchConfig(_ config: SoundTouchConfig) {
        precondition(!released, "AudioPipelineCore: instance has been released")
        assertSingleTap("setSoundTouchConfig")
        let tap = tapList[0]
        if config.enabled {
            tap.soundTouchConfig = config
            ensureSoundTouchForTap(tap)
            if let ctx = tap.stContext {
                st_set_pitch_semitones(ctx, config.pitchSemiTones)
            }
        } else {
            tap.soundTouchConfig = nil
            if let ctx = tap.stContext {
                st_destroy(ctx)
                tap.stContext = nil
            }
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

    // MARK: - Internals

    /// Pull one frame through every tap. Assumes ``rawFrameScratch`` is already
    /// populated; writes into `outputs[tapId]` at offset `writeOffset`. Shared
    /// denoise inference runs at most once per frame regardless of tap count.
    private func runFrameIntoTaps(writeOffset: Int, outputs: inout [String: [Float]]) {
        let frameLen = frameLength
        var denoisedReady = false

        for tap in tapList {
            // Decide which base frame this tap consumes — denoised or raw —
            // and copy it into tapFrameScratch so SoundTouch can mutate in place.
            let useDenoised: Bool
            if tap.denoise {
                switch activeModule {
                case .rnnoise:
                    useDenoised = (rnnoiseWrapper != nil)
                case .deepfilternet:
                    useDenoised = (dfContext != nil && dfFrameLength == frameLen)
                }
            } else {
                useDenoised = false
            }

            if useDenoised {
                if !denoisedReady {
                    populateDenoisedScratch(frameLen: frameLen)
                    denoisedReady = true
                }
                for i in 0..<frameLen { tapFrameScratch[i] = denoisedFrameScratch[i] }
            } else {
                // Either this tap doesn't want denoise, or the backend isn't
                // available — fall back to raw rather than producing zeros.
                for i in 0..<frameLen { tapFrameScratch[i] = rawFrameScratch[i] }
            }

            if let ctx = tap.stContext, tap.soundTouchConfig?.enabled == true {
                applySoundTouch(ctx: ctx, frame: &tapFrameScratch)
            }

            // Splice into the per-tap output buffer at writeOffset. Pull the
            // array out of the dictionary first so we mutate exactly one CoW
            // backing buffer instead of repeatedly hashing the key.
            if var arr = outputs[tap.id] {
                arr.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    let dst = base.advanced(by: writeOffset)
                    tapFrameScratch.withUnsafeBufferPointer { src in
                        if let srcBase = src.baseAddress {
                            dst.update(from: srcBase, count: frameLen)
                        }
                    }
                }
                outputs[tap.id] = arr
            }
        }
    }

    /// Run shared denoise once over ``rawFrameScratch`` into ``denoisedFrameScratch``.
    /// Caller is responsible for gating on whether at least one tap wants it.
    private func populateDenoisedScratch(frameLen: Int) {
        switch activeModule {
        case .rnnoise:
            for i in 0..<frameLen { denoisedFrameScratch[i] = rawFrameScratch[i] }
            if let wrapper = rnnoiseWrapper {
                applyRnnoise(wrapper: wrapper, frame: &denoisedFrameScratch)
            }
        case .deepfilternet:
            for i in 0..<frameLen { dfInputBuffer[i] = rawFrameScratch[i] }
            if let ctx = dfContext {
                dfInputBuffer.withUnsafeMutableBufferPointer { inPtr in
                    dfOutputBuffer.withUnsafeMutableBufferPointer { outPtr in
                        _ = df_process_frame(ctx, inPtr.baseAddress, outPtr.baseAddress)
                    }
                }
            }
            for i in 0..<frameLen { denoisedFrameScratch[i] = dfOutputBuffer[i] }
        }
    }

    private func makeEmptyTapOutputs(perTapLength: Int) -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        out.reserveCapacity(tapList.count)
        for tap in tapList {
            out[tap.id] = [Float](repeating: 0, count: perTapLength)
        }
        return out
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

    private func ensureSoundTouchForTap(_ tap: TapState) {
        if tap.stContext != nil { return }
        guard let config = tap.soundTouchConfig, config.enabled else { return }
        guard let ctx = st_create(48000) else { return }
        tap.stContext = ctx
        st_set_pitch_semitones(ctx, config.pitchSemiTones)
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
        rawFrameScratch = [Float](repeating: 0, count: newLength)
        denoisedFrameScratch = [Float](repeating: 0, count: newLength)
        tapFrameScratch = [Float](repeating: 0, count: newLength)
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

    private func assertSingleTap(_ method: String) {
        if multiTap {
            preconditionFailure(
                "AudioPipelineCore.\(method)() is not valid on a multi-tap pipeline. " +
                "Use \(method)Taps() (or the matching method on OfflineAudioPipeline) instead."
            )
        }
    }
}
