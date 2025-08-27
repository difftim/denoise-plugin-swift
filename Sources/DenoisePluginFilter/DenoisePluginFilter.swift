import AVFoundation
import Combine
import Foundation
import LiveKit
import RNNoise

public class DenoisePluginFilter {
    public var isEnabled: Bool {
        get { _state.isEnabled }
        set { _state.mutate { $0.isEnabled = newValue } }
    }

    private var rnn: RNNoiseWrapper?

    private struct State {
        var isEnabled: Bool = true
        var supportSampleRateHz: Int = 48000
        var supportChannels: Int = 1
        var sampleRateHz: Int?
        var channels: Int?
        var debugLog: Bool = false
        var vadLogs: Bool = false
        var converterTo48K: AVAudioConverter? = nil
        var converterToSrc: AVAudioConverter? = nil
    }

    private let _state = StateSync(State())

    public init(debugLog: Bool = false, vadLogs: Bool = false) {
        _state.mutate {
            $0.debugLog = debugLog
            $0.vadLogs = vadLogs
        }
    }
}

extension DenoisePluginFilter: AudioCustomProcessingDelegate {
    public var audioProcessingName: String { "denoise-filter" }

    // This will be invoked anytime sample rate changes, for example switching Speaker <-> AirPods.
    public func audioProcessingInitialize(
        sampleRate sampleRateHz: Int,
        channels: Int
    ) {
        if _state.debugLog {
            print(
                "DenoisePluginFilter: initialize: sampleRateHz=\(sampleRateHz), channels=\(channels)"
            )
        }

        let isNeedInit = _state.mutate {
            let result =
                ($0.sampleRateHz != sampleRateHz || $0.channels != channels)
            $0.sampleRateHz = sampleRateHz
            $0.channels = channels
            return result
        }

        if isNeedInit {
            rnn = nil
            _state.mutate {
                $0.converterTo48K = nil
                $0.converterToSrc = nil
            }

            rnn = RNNoiseWrapper()
            rnn?.initialize(
                Int32(_state.supportSampleRateHz),
                numChannels: Int32(_state.supportChannels)
            )

            if _state.debugLog {
                print(
                    "DenoisePluginFilter: initialize: sampleRateHz=\(sampleRateHz), channels=\(channels), rnn=\(rnn)"
                )
            }
        }
    }

    public func audioProcessingProcess(audioBuffer: LiveKit.LKAudioBuffer) {
        guard _state.isEnabled else { return }

        guard audioBuffer.channels == _state.channels else {
            return
        }

        var vads: [Float] = Array(repeating: 0.0, count: audioBuffer.channels)
        let needResample: Bool =
            _state.sampleRateHz != _state.supportSampleRateHz

        defer {
            if _state.debugLog && _state.vadLogs {
                print(
                    "DenoisePluginFilter: resample&process: channels=\(audioBuffer.channels), withBands=\(audioBuffer.bands), frames=\(audioBuffer.frames), bufferSize=\(audioBuffer.framesPerBand), vads=\(vads)"
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

    public func audioProcessingRelease() {
        if _state.debugLog {
            print("DenoisePluginFilter: release: rnn=\(rnn)")
        }
        rnn = nil
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
            // sourceBuffer is in the format of [Int16] but is stored in 32-bit alignment, we need to pack the Int16 data correctly.

            for frame in 0..<frames {
                // Cast and pack the source 32-bit Int16 data into the target 16-bit buffer
                let clampedValue = max(
                    Float(Int16.min),
                    min(Float(Int16.max), sourceBuffer[frame])
                )
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
            // sourceBuffer is in the format of [Int16] but is stored in 32-bit alignment, we need to pack the Int16 data correctly.

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
            // Won't be accessed concurrently, marking as nonisolated(unsafe) to avoid Atomics.
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

        // Adjust frame length to the actual amount of data written
        convertedBuffer.frameLength = convertedBuffer.frameCapacity

        return convertedBuffer
    }
}
