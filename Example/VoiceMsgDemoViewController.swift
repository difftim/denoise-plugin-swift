//
//  VoiceMsgDemoViewController.swift
//  AudioPipelineProcessor SDK demo
//
//  Reference UIKit view controller for the SDK's `OfflineAudioPipeline`.
//  Drop this single file into any iOS app that depends on the
//  `AudioPipelineProcessor` Swift package, and present it from anywhere:
//
//      let vc = VoiceMsgDemoViewController()
//      navigationController?.pushViewController(vc, animated: true)
//
//  What it does
//  ------------
//  Captures one mic stream via AVAudioEngine, resamples to 48 kHz mono float32,
//  and writes the PCM into two AVAudioFile instances in parallel:
//   - `original-<ts>.m4a` — raw passthrough, never touches the SDK.
//   - `processed-<ts>.m4a` — same PCM run through `OfflineAudioPipeline`
//     (RNNoise denoise + optional voice changer at +4 semitones).
//
//  Buttons: Start / Stop / Cancel / Play original / Play processed.
//

import AVFoundation
import AudioPipelineProcessor
import UIKit

public final class VoiceMsgDemoViewController: UIViewController {

    // MARK: - Audio plumbing

    private let engine = AVAudioEngine()
    private let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 1,
        interleaved: false
    )!
    private let writerFormatSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
    ]

    private var originalFile: AVAudioFile?
    private var processedFile: AVAudioFile?
    private var inputToProcessingConverter: AVAudioConverter?

    private var pipeline: OfflineAudioPipeline?
    private var originalURL: URL?
    private var processedURL: URL?

    private var originalPlayer: AVAudioPlayer?
    private var processedPlayer: AVAudioPlayer?

    private enum RecordingState { case idle, recording, stopped, cancelled }
    private var recordingState: RecordingState = .idle

    // MARK: - UI

    private let statusLabel = UILabel()
    private let originalInfoLabel = UILabel()
    private let processedInfoLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let playOriginalButton = UIButton(type: .system)
    private let playProcessedButton = UIButton(type: .system)
    private let denoiseSwitch = UISwitch()
    private let voiceChangerSwitch = UISwitch()

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "OfflineAudioPipeline demo"
        view.backgroundColor = .systemBackground
        setupUI()
        refreshUI()
    }

    deinit {
        pipeline?.release()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    // MARK: - UI setup

    private func setupUI() {
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        for label in [originalInfoLabel, processedInfoLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
        }

        configure(button: startButton, title: "Start", action: #selector(onStart))
        configure(button: stopButton, title: "Stop", action: #selector(onStop))
        configure(button: cancelButton, title: "Cancel", action: #selector(onCancel))
        configure(button: playOriginalButton, title: "Play original", action: #selector(onPlayOriginal))
        configure(button: playProcessedButton, title: "Play processed", action: #selector(onPlayProcessed))

        denoiseSwitch.isOn = true
        voiceChangerSwitch.isOn = true

        let denoiseRow = switchRow(title: "Denoise (RNNoise)", control: denoiseSwitch)
        let voiceRow = switchRow(title: "Voice changer (+4 semitones)", control: voiceChangerSwitch)

        let controlRow = UIStackView(arrangedSubviews: [startButton, stopButton, cancelButton])
        controlRow.axis = .horizontal
        controlRow.distribution = .fillEqually
        controlRow.spacing = 12

        let playRow = UIStackView(arrangedSubviews: [playOriginalButton, playProcessedButton])
        playRow.axis = .horizontal
        playRow.distribution = .fillEqually
        playRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [
            statusLabel, denoiseRow, voiceRow, controlRow,
            originalInfoLabel, processedInfoLabel, playRow,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    private func configure(button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func switchRow(title: String, control: UISwitch) -> UIView {
        let label = UILabel()
        label.text = title
        label.textColor = .label
        label.font = .systemFont(ofSize: 14)
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    private func refreshUI() {
        switch recordingState {
        case .idle:       statusLabel.text = "Idle — tap Start to record"
        case .recording:  statusLabel.text = "Recording..."
        case .stopped:    statusLabel.text = "Stopped — both candidates ready"
        case .cancelled:  statusLabel.text = "Cancelled"
        }
        startButton.isEnabled = (recordingState != .recording)
        stopButton.isEnabled = (recordingState == .recording)
        cancelButton.isEnabled = (recordingState == .recording)
        playOriginalButton.isEnabled = (originalURL != nil && recordingState != .recording)
        playProcessedButton.isEnabled = (processedURL != nil && recordingState != .recording)
        denoiseSwitch.isEnabled = (recordingState != .recording)
        voiceChangerSwitch.isEnabled = (recordingState != .recording)

        originalInfoLabel.text = describe(url: originalURL, label: "original")
        processedInfoLabel.text = describe(url: processedURL, label: "processed")
    }

    private func describe(url: URL?, label: String) -> String {
        guard let url else { return "\(label): —" }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let duration = audioDuration(for: url)
        return String(
            format: "%@: %@\n  size=%dB  duration=%.2fs",
            label, url.lastPathComponent, size, duration
        )
    }

    private func audioDuration(for url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: - Actions

    @objc private func onStart() {
        cleanupPlayers()
        do {
            try startRecording()
            recordingState = .recording
        } catch {
            statusLabel.text = "Start failed: \(error.localizedDescription)"
        }
        refreshUI()
    }

    @objc private func onStop() {
        finishRecording(deleteFiles: false)
        recordingState = .stopped
        refreshUI()
    }

    @objc private func onCancel() {
        finishRecording(deleteFiles: true)
        recordingState = .cancelled
        refreshUI()
    }

    @objc private func onPlayOriginal() {
        playFile(at: originalURL, into: &originalPlayer)
    }

    @objc private func onPlayProcessed() {
        playFile(at: processedURL, into: &processedPlayer)
    }

    // MARK: - Recording impl

    private func startRecording() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-msg-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let originalURL = dir.appendingPathComponent("original-\(stamp).m4a")
        let processedURL = dir.appendingPathComponent("processed-\(stamp).m4a")
        self.originalURL = originalURL
        self.processedURL = processedURL

        let originalFile = try AVAudioFile(forWriting: originalURL, settings: writerFormatSettings)
        let processedFile = try AVAudioFile(forWriting: processedURL, settings: writerFormatSettings)
        self.originalFile = originalFile
        self.processedFile = processedFile

        let pipeline = OfflineAudioPipeline(
            initialModule: .rnnoise,
            soundTouchConfig: SoundTouchConfig(
                enabled: voiceChangerSwitch.isOn,
                pitchSemiTones: 4
            ),
            denoiseEnabled: denoiseSwitch.isOn
        )
        self.pipeline = pipeline

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputToProcessingConverter = AVAudioConverter(from: inputFormat, to: processingFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        try engine.start()
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let pipeline = pipeline,
              let originalFile = originalFile,
              let processedFile = processedFile,
              let converter = inputToProcessingConverter else {
            return
        }

        let outputCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (processingFormat.sampleRate / buffer.format.sampleRate) + 16
        )
        guard let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: max(outputCapacity, 1)
        ) else { return }

        var fed = false
        let status = converter.convert(to: monoBuffer, error: nil) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, monoBuffer.frameLength > 0 else { return }

        // Branch A: write the unprocessed mono buffer.
        try? originalFile.write(from: monoBuffer)

        // Branch B: hand the same samples to the SDK and write the result.
        guard let chPtr = monoBuffer.floatChannelData?[0] else { return }
        let inputArray = Array(UnsafeBufferPointer(start: chPtr, count: Int(monoBuffer.frameLength)))
        let processed = pipeline.process(inputArray)
        if !processed.isEmpty {
            writeFloats(processed, to: processedFile)
        }
    }

    private func writeFloats(_ samples: [Float], to file: AVAudioFile) {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        try? file.write(from: buffer)
    }

    private func finishRecording(deleteFiles: Bool) {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        if !deleteFiles, let pipeline = pipeline, let processedFile = processedFile {
            let tail = pipeline.flush()
            if !tail.isEmpty { writeFloats(tail, to: processedFile) }
        }

        originalFile = nil
        processedFile = nil
        pipeline?.release()
        pipeline = nil
        inputToProcessingConverter = nil

        if deleteFiles {
            if let url = originalURL { try? FileManager.default.removeItem(at: url) }
            if let url = processedURL { try? FileManager.default.removeItem(at: url) }
            originalURL = nil
            processedURL = nil
        }
    }

    private func playFile(at url: URL?, into player: inout AVAudioPlayer?) {
        guard let url else { return }
        cleanupPlayers()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            statusLabel.text = "Play failed: \(error.localizedDescription)"
        }
    }

    private func cleanupPlayers() {
        originalPlayer?.stop()
        processedPlayer?.stop()
        originalPlayer = nil
        processedPlayer = nil
    }
}
