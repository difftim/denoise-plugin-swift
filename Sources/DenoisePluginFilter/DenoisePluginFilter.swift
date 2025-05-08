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
            guard
                let processBuffer = audioBuffer.toAVAudioPCMBufferFloat()?
                    .resample(toSampleRate: Double(_state.supportSampleRateHz)),
                processBuffer.floatChannelData != nil
            else {
                return
            }

            for channel in 0..<audioBuffer.channels {
                guard
                    let floatPointer: UnsafeMutablePointer<Float> =
                        processBuffer.floatChannelData?[channel]
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
                let afterProcessBuffer = processBuffer.resample(
                    toSampleRate: Double(_state.sampleRateHz!)
                )
            else {
                return
            }

            audioBuffer.rewriteByAVAudioPCMBuffer(buffer: afterProcessBuffer)

        } else {
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
