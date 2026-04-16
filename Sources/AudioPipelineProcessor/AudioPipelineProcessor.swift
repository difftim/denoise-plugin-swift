import AudioPipeline
import AVFoundation
import Combine
import Foundation
import LiveKit

public enum AudioModule: String {
    case rnnoise
    case deepfilternet
}

public struct SoundTouchConfig {
    public var enabled: Bool
    public var pitchSemiTones: Float

    public init(enabled: Bool = false, pitchSemiTones: Float = 0) {
        self.enabled = enabled
        self.pitchSemiTones = pitchSemiTones
    }

    public static let presets: [String: SoundTouchConfig] = [
        "loli":     SoundTouchConfig(enabled: true,  pitchSemiTones:  12),
        "uncle":    SoundTouchConfig(enabled: true,  pitchSemiTones:  -4),
        "goddess":  SoundTouchConfig(enabled: true,  pitchSemiTones:   4),
        "monster":  SoundTouchConfig(enabled: true,  pitchSemiTones: -10),
        "original": SoundTouchConfig(enabled: false, pitchSemiTones:   0),
    ]
}

public struct DeepFilterConfig {
    public var attenLimDb: Float
    public var postFilterBeta: Float
    public var minDbThresh: Float
    public var maxDbErbThresh: Float
    public var maxDbDfThresh: Float

    public init(
        attenLimDb: Float = 100,
        postFilterBeta: Float = 0,
        minDbThresh: Float = -15,
        maxDbErbThresh: Float = 35,
        maxDbDfThresh: Float = 35
    ) {
        self.attenLimDb = attenLimDb
        self.postFilterBeta = postFilterBeta
        self.minDbThresh = minDbThresh
        self.maxDbErbThresh = maxDbErbThresh
        self.maxDbDfThresh = maxDbDfThresh
    }
}

public typealias DenoisePluginFilter = AudioPipelineProcessor

public class AudioPipelineProcessor {
    @available(*, deprecated, renamed: "setDenoiseEnabled(_:)")
    public var isEnabled: Bool {
        get { _state.isEnabled }
        set { _state.mutate { $0.isEnabled = newValue } }
    }

    public var activeModule: AudioModule {
        get { _state.activeModule }
        set {
            _state.mutate { $0.activeModule = newValue }
            if _state.debugLog {
                print("AudioPipeline: setModule -> \(newValue.rawValue)")
            }
        }
    }

    private var rnn: RNNoiseWrapper?

    private var dfContext: OpaquePointer?
    private var dfFrameLength: Int = 0
    private var dfOutputBuffer: UnsafeMutablePointer<Float>?

    private var stContext: OpaquePointer?

    private struct State {
        var isEnabled: Bool = true
        var activeModule: AudioModule = .rnnoise
        var supportSampleRateHz: Int = 48000
        var supportChannels: Int = 1
        var sampleRateHz: Int?
        var channels: Int?
        var debugLog: Bool = false
        var vadLogs: Bool = false
        var converterTo48K: AVAudioConverter?
        var converterToSrc: AVAudioConverter?
        var hasInitialized: Bool = false
        var deepFilterConfig: DeepFilterConfig = .init()
        var soundTouchConfig: SoundTouchConfig = .init()
    }

    private let _state = StateSync(State())

    public init(
        debugLog: Bool = false,
        vadLogs: Bool = false,
        initialModule: AudioModule = .rnnoise,
        deepFilterConfig: DeepFilterConfig = .init(),
        soundTouchConfig: SoundTouchConfig = .init()
    ) {
        _state.mutate {
            $0.debugLog = debugLog
            $0.vadLogs = vadLogs
            $0.activeModule = initialModule
            $0.deepFilterConfig = deepFilterConfig
            $0.soundTouchConfig = soundTouchConfig
        }
    }

    deinit {
        if _state.debugLog {
            print("AudioPipeline: deinit release: rnn=\(String(describing: rnn)), dfContext=\(String(describing: dfContext)), stContext=\(String(describing: stContext))")
        }

        releaseInternal()
    }

    // MARK: - Denoise / VoiceChanger Switches

    public func setDenoiseEnabled(_ enabled: Bool) {
        _state.mutate { $0.isEnabled = enabled }
        if _state.debugLog {
            print("AudioPipeline: setDenoiseEnabled: \(enabled)")
        }
    }

    public func setVoiceChangerEnabled(_ enabled: Bool) {
        var config = _state.soundTouchConfig
        config.enabled = enabled
        setSoundTouchConfig(config)
    }

    // MARK: - SoundTouch Config

    public func setSoundTouchConfig(_ config: SoundTouchConfig) {
        _state.mutate { $0.soundTouchConfig = config }
        if let ctx = stContext {
            st_set_pitch_semitones(ctx, config.pitchSemiTones)
        }
        if _state.debugLog {
            print("AudioPipeline: setSoundTouchConfig: enabled=\(config.enabled), pitchSemiTones=\(config.pitchSemiTones)")
        }
    }

    public func setSoundTouchPreset(_ preset: String) {
        let config = SoundTouchConfig.presets[preset] ?? SoundTouchConfig(enabled: true, pitchSemiTones: 0)
        setSoundTouchConfig(config)
    }

    // MARK: - DeepFilterNet Config

    public func updateDeepFilterConfig(_ config: DeepFilterConfig) {
        _state.mutate { $0.deepFilterConfig = config }

        if let ctx = dfContext {
            df_set_atten_lim(ctx, config.attenLimDb)
            df_set_post_filter_beta(ctx, config.postFilterBeta)
        }

        if _state.debugLog {
            print("AudioPipeline: updateDeepFilterConfig: attenLimDb=\(config.attenLimDb), postFilterBeta=\(config.postFilterBeta)")
        }
    }
}

extension AudioPipelineProcessor: AudioCustomProcessingDelegate {
    public var audioProcessingName: String { "audio-pipeline" }

    public func audioProcessingInitialize(
        sampleRate sampleRateHz: Int,
        channels: Int
    ) {
        initInternal(
            sampleRate: sampleRateHz,
            channels: channels,
            fromProcess: false
        )
    }

    public func audioProcessingProcess(audioBuffer: LiveKit.LKAudioBuffer) {
        if !_state.hasInitialized {
            initInternal(
                sampleRate: audioBuffer.frames * 100,
                channels: audioBuffer.channels,
                fromProcess: true
            )
        }

        guard audioBuffer.channels == _state.channels else { return }

        if _state.isEnabled {
            switch _state.activeModule {
            case .rnnoise:
                processRnnoise(audioBuffer: audioBuffer)
            case .deepfilternet:
                processDeepFilter(audioBuffer: audioBuffer)
            }
        }

        if _state.soundTouchConfig.enabled {
            processSoundTouch(audioBuffer: audioBuffer)
        }
    }

    // MARK: - RNNoise Processing

    private func processRnnoise(audioBuffer: LiveKit.LKAudioBuffer) {
        var vads: [Float] = Array(repeating: 0.0, count: audioBuffer.channels)
        let needResample: Bool =
            _state.sampleRateHz != _state.supportSampleRateHz

        defer {
            if _state.debugLog && _state.vadLogs {
                print(
                    "AudioPipeline: rnnoise: channels=\(audioBuffer.channels), withBands=\(audioBuffer.bands), frames=\(audioBuffer.frames), bufferSize=\(audioBuffer.framesPerBand), vads=\(vads)"
                )
            }
        }

        if needResample {
            guard let srcFloat32 = audioBuffer.toAVAudioPCMBufferFloat() else {
                return
            }

            _state.mutate {
                if $0.converterTo48K == nil || $0.converterToSrc == nil {
                    guard
                        let targetFormat = AVAudioFormat(
                            commonFormat: srcFloat32.format.commonFormat,
                            sampleRate: Double($0.supportSampleRateHz),
                            channels: srcFloat32.format.channelCount,
                            interleaved: srcFloat32.format.isInterleaved
                        )
                    else { return }

                    $0.converterTo48K = AVAudioConverter(
                        from: srcFloat32.format,
                        to: targetFormat
                    )
                    $0.converterToSrc = AVAudioConverter(
                        from: targetFormat,
                        to: srcFloat32.format
                    )
                }
            }

            guard
                let converterTo48K = _state.converterTo48K,
                let srcFloat32Resample = srcFloat32.resampleStream(
                    converterTo48K
                )
            else { return }

            for channel in 0..<audioBuffer.channels {
                guard
                    let floatPointer = srcFloat32Resample.floatChannelData?[
                        channel
                    ]
                else {
                    return
                }

                vads[channel] =
                    (rnn?.process(
                        withBands: Int32(3),
                        frames: Int32(480),
                        bufferSize: Int32(160),
                        buffer: floatPointer
                    ))!
            }

            guard
                let converterToSrc = _state.converterToSrc,
                let dstFloat32Resample = srcFloat32Resample.resampleStream(
                    converterToSrc
                )
            else {
                return
            }

            audioBuffer.rewriteByAVAudioPCMBuffer(buffer: dstFloat32Resample)

        } else {
            _state.mutate {
                $0.converterTo48K = nil
                $0.converterToSrc = nil
            }

            for channel in 0..<audioBuffer.channels {
                vads[channel] =
                    (rnn?.process(
                        withBands: Int32(audioBuffer.bands),
                        frames: Int32(audioBuffer.frames),
                        bufferSize: Int32(audioBuffer.framesPerBand),
                        buffer: audioBuffer.rawBuffer(forChannel: channel)
                    ))!
            }
        }
    }

    // MARK: - DeepFilterNet Processing

    private func processDeepFilter(audioBuffer: LiveKit.LKAudioBuffer) {
        guard let ctx = dfContext, dfFrameLength > 0 else { return }

        let needResample: Bool =
            _state.sampleRateHz != _state.supportSampleRateHz

        if needResample {
            guard let srcFloat32 = audioBuffer.toAVAudioPCMBufferFloat() else {
                return
            }

            _state.mutate {
                if $0.converterTo48K == nil || $0.converterToSrc == nil {
                    guard
                        let targetFormat = AVAudioFormat(
                            commonFormat: srcFloat32.format.commonFormat,
                            sampleRate: Double($0.supportSampleRateHz),
                            channels: srcFloat32.format.channelCount,
                            interleaved: srcFloat32.format.isInterleaved
                        )
                    else { return }

                    $0.converterTo48K = AVAudioConverter(
                        from: srcFloat32.format,
                        to: targetFormat
                    )
                    $0.converterToSrc = AVAudioConverter(
                        from: targetFormat,
                        to: srcFloat32.format
                    )
                }
            }

            guard
                let converterTo48K = _state.converterTo48K,
                let srcFloat32Resample = srcFloat32.resampleStream(converterTo48K)
            else { return }

            guard let floatPointer = srcFloat32Resample.floatChannelData?[0] else {
                return
            }

            let lsnr = processDeepFilterFrame(ctx: ctx, input: floatPointer, frameCount: Int(srcFloat32Resample.frameLength))

            if _state.debugLog && _state.vadLogs {
                print("AudioPipeline: deepfilter (resampled): frames=\(srcFloat32Resample.frameLength), lsnr=\(lsnr)")
            }

            guard
                let converterToSrc = _state.converterToSrc,
                let dstFloat32Resample = srcFloat32Resample.resampleStream(converterToSrc)
            else { return }

            audioBuffer.rewriteByAVAudioPCMBuffer(buffer: dstFloat32Resample)

        } else {
            let rawBuffer = audioBuffer.rawBuffer(forChannel: 0)
            let frameCount = audioBuffer.frames

            let lsnr = processDeepFilterFrame(ctx: ctx, input: rawBuffer, frameCount: frameCount)

            if _state.debugLog && _state.vadLogs {
                print("AudioPipeline: deepfilter: frames=\(frameCount), lsnr=\(lsnr)")
            }
        }
    }

    private static let int16ToFloat: Float = 1.0 / 32768.0
    private static let floatToInt16: Float = 32768.0

    private func processDeepFilterFrame(
        ctx: OpaquePointer,
        input: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Float {
        guard let outputBuf = dfOutputBuffer else { return 0 }

        var lsnr: Float = 0
        var offset = 0

        while offset + dfFrameLength <= frameCount {
            let framePtr = input.advanced(by: offset)

            for i in 0..<dfFrameLength {
                framePtr[i] *= Self.int16ToFloat
            }

            lsnr = df_process_frame(ctx, framePtr, outputBuf)

            for i in 0..<dfFrameLength {
                framePtr[i] = outputBuf[i] * Self.floatToInt16
            }

            offset += dfFrameLength
        }

        return lsnr
    }

    // MARK: - SoundTouch Processing

    private func processSoundTouch(audioBuffer: LiveKit.LKAudioBuffer) {
        guard let ctx = stContext else { return }
        let rawBuffer = audioBuffer.rawBuffer(forChannel: 0)
        st_process_frame(ctx, rawBuffer, Int32(audioBuffer.frames))
    }

    // MARK: - Init / Release

    private func initInternal(
        sampleRate sampleRateHz: Int,
        channels: Int,
        fromProcess: Bool
    ) {
        if _state.debugLog {
            print(
                "AudioPipeline: initialize(fromProcess=\(fromProcess)): sampleRateHz=\(sampleRateHz), channels=\(channels)"
            )
        }
        let isNeedInit = _state.mutate {
            let result =
                ($0.sampleRateHz != sampleRateHz || $0.channels != channels
                    || !$0.hasInitialized)
            $0.sampleRateHz = sampleRateHz
            $0.channels = channels
            $0.hasInitialized = true
            return result
        }

        if isNeedInit {
            releaseInternal()

            initRnnoise()
            initDeepFilter()
            initSoundTouch()

            if _state.debugLog {
                print(
                    "AudioPipeline: initialize(fromProcess=\(fromProcess)): sampleRateHz=\(sampleRateHz), channels=\(channels), rnn=\(String(describing: rnn)), dfContext=\(String(describing: dfContext))"
                )
            }
        }
    }

    private func initRnnoise() {
        rnn = RNNoiseWrapper()
        rnn?.initialize(
            Int32(_state.supportSampleRateHz),
            numChannels: Int32(_state.supportChannels)
        )
    }

    private func initSoundTouch() {
        let sampleRate = _state.sampleRateHz ?? 48000
        guard let ctx = st_create(Int32(sampleRate)) else { return }
        stContext = ctx
        st_set_pitch_semitones(ctx, _state.soundTouchConfig.pitchSemiTones)
        if _state.debugLog {
            print("AudioPipeline: SoundTouch initialized, sampleRate=\(sampleRate)")
        }
    }

    private func initDeepFilter() {
        let cfg = _state.deepFilterConfig
        let st = df_create_default(
            cfg.attenLimDb,
            cfg.minDbThresh,
            cfg.maxDbErbThresh,
            cfg.maxDbDfThresh
        )

        guard let ctx = st else {
            if _state.debugLog {
                print("AudioPipeline: failed to create DeepFilterNet state")
            }
            return
        }

        dfContext = ctx
        dfFrameLength = df_get_frame_length(ctx)
        dfOutputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: dfFrameLength)

        df_set_atten_lim(ctx, cfg.attenLimDb)
        df_set_post_filter_beta(ctx, cfg.postFilterBeta)

        if _state.debugLog {
            print("AudioPipeline: DeepFilterNet initialized, frameLength=\(dfFrameLength)")
        }
    }

    public func audioProcessingRelease() {
        if _state.debugLog {
            print("AudioPipeline: release: rnn=\(String(describing: rnn)), dfContext=\(String(describing: dfContext))")
        }

        releaseInternal()
    }

    private func releaseInternal() {
        rnn = nil

        if let ctx = dfContext {
            df_free(ctx)
            dfContext = nil
        }
        dfFrameLength = 0
        if let buf = dfOutputBuffer {
            buf.deallocate()
            dfOutputBuffer = nil
        }

        if let ctx = stContext {
            st_destroy(ctx)
            stContext = nil
        }

        _state.mutate {
            $0.converterTo48K = nil
            $0.converterToSrc = nil
        }
    }
}

extension LKAudioBuffer {
    @objc
    public func toAVAudioPCMBufferFloat() -> AVAudioPCMBuffer? {
        guard
            let audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(frames * 100),
                channels: AVAudioChannelCount(channels),
                interleaved: false
            ),
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(frames)
            )
        else { return nil }

        pcmBuffer.frameLength = AVAudioFrameCount(frames)

        guard let targetBufferPointer = pcmBuffer.floatChannelData else {
            return nil
        }

        for i in 0..<channels {
            let sourceBuffer = rawBuffer(forChannel: i)
            let targetBuffer = targetBufferPointer[i]

            for frame in 0..<frames {
                targetBuffer[frame] = sourceBuffer[frame]
            }
        }

        return pcmBuffer
    }

    @objc
    public func rewriteByAVAudioPCMBuffer(buffer: AVAudioPCMBuffer) {
        guard let targetBufferPointer = buffer.floatChannelData else {
            return
        }

        for i in 0..<channels {
            let sourceBuffer: UnsafeMutablePointer<Float> =
                (buffer.floatChannelData?[i])!
            let targetBuffer = rawBuffer(forChannel: i)

            for frame in 0..<frames {
                targetBuffer[frame] = sourceBuffer[frame]
            }
        }
    }
}

extension AVAudioPCMBuffer {
    public func resampleStream(_ converter: AVAudioConverter)
        -> AVAudioPCMBuffer?
    {
        let sourceFormat = format

        let capacity =
            converter.outputFormat.sampleRate * Double(frameLength)
            / sourceFormat.sampleRate

        guard
            let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(capacity)
            )
        else {
            return nil
        }

        #if swift(>=6.0)
            nonisolated(unsafe) var isDone = false
        #else
            var isDone = false
        #endif
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            isDone = true
            return self
        }

        var error: NSError?
        let status = converter.convert(
            to: convertedBuffer,
            error: &error,
            withInputFrom: inputBlock
        )

        if status == .error {
            return nil
        }

        convertedBuffer.frameLength = convertedBuffer.frameCapacity

        return convertedBuffer
    }
}
