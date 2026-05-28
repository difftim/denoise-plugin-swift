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
//  and writes the PCM into three .m4a files in parallel using ONE
//  multi-tap `OfflineAudioPipeline` (denoise inference runs once per chunk,
//  fans out to N output taps):
//   - `original-<ts>.m4a`  — raw passthrough, never touches the SDK.
//   - `denoised-<ts>.m4a`  — tap "denoised":         denoise on, no voice changer.
//   - `processed-<ts>.m4a` — tap "denoised+pitch":   denoise on + SoundTouch
//                            at the selected pitch.
//
//  Buttons: Start / Stop / Cancel / Play original / Play denoised / Play processed.
//

import AVFoundation
import AudioPipelineProcessor
import UIKit

public final class VoiceMsgDemoViewController: UIViewController {

    // MARK: - Audio plumbing

    private var engine = AVAudioEngine()
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

    private var inputToProcessingConverter: AVAudioConverter?

    /// Single multi-tap pipeline shared by all SDK-driven outputs. Tap ids:
    ///   - `denoisedTapId`  → denoise only
    ///   - `processedTapId` → denoise + SoundTouch (pitch from UI)
    private var pipeline: OfflineAudioPipeline?
    private let denoisedTapId = "denoised"
    private let processedTapId = "denoised+pitch"
    private var originalURL: URL?
    private var denoisedURL: URL?
    private var processedURL: URL?
    private var originalChunks: [[Float]] = []
    private var denoisedChunks: [[Float]] = []
    private var processedChunks: [[Float]] = []
    private var startTimestamp: CFAbsoluteTime = 0
    private var tapFrameCount: Int = 0

    private var originalPlayer: AVPlayer?
    private var denoisedPlayer: AVPlayer?
    private var processedPlayer: AVPlayer?

    private enum RecordingState { case idle, preparing, recording, stopped, cancelled }
    private var recordingState: RecordingState = .idle

    // MARK: - UI

    private let statusLabel = UILabel()
    private let originalInfoLabel = UILabel()
    private let denoisedInfoLabel = UILabel()
    private let processedInfoLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let playOriginalButton = UIButton(type: .system)
    private let playDenoisedButton = UIButton(type: .system)
    private let playProcessedButton = UIButton(type: .system)
    private let denoiseModelControl = UISegmentedControl(items: ["RNNoise", "DeepFilterNet"])
    private let voicePresetControl = UISegmentedControl(items: ["Original", "Loli", "Goddess", "Uncle", "Monster"])
    private let denoiseSwitch = UISwitch()
    private let voiceChangerSwitch = UISwitch()

    private let voicePresetPitchValues: [Float?] = [
        nil, 12, 4, -4, -10,
    ]

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

        for label in [originalInfoLabel, denoisedInfoLabel, processedInfoLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
        }

        configure(button: startButton, title: "Start", action: #selector(onStart))
        configure(button: stopButton, title: "Stop", action: #selector(onStop))
        configure(button: cancelButton, title: "Cancel", action: #selector(onCancel))
        configure(button: playOriginalButton, title: "Play original", action: #selector(onPlayOriginal))
        configure(button: playDenoisedButton, title: "Play denoised", action: #selector(onPlayDenoised))
        configure(button: playProcessedButton, title: "Play processed", action: #selector(onPlayProcessed))

        denoiseModelControl.selectedSegmentIndex = 0
        voicePresetControl.selectedSegmentIndex = 2
        denoiseSwitch.isOn = true
        voiceChangerSwitch.isOn = true

        let denoiseModelRow = segmentedRow(title: "Denoise model", control: denoiseModelControl)
        let denoiseRow = switchRow(title: "Enable denoise", control: denoiseSwitch)
        let voicePresetRow = segmentedRow(title: "Voice preset", control: voicePresetControl)
        let voiceRow = switchRow(title: "Enable voice changer", control: voiceChangerSwitch)

        let controlRow = UIStackView(arrangedSubviews: [startButton, stopButton, cancelButton])
        controlRow.axis = .horizontal
        controlRow.distribution = .fillEqually
        controlRow.spacing = 12

        let playRow = UIStackView(arrangedSubviews: [playOriginalButton, playDenoisedButton, playProcessedButton])
        playRow.axis = .horizontal
        playRow.distribution = .fillEqually
        playRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [
            statusLabel, denoiseModelRow, denoiseRow, voicePresetRow, voiceRow, controlRow,
            originalInfoLabel, denoisedInfoLabel, processedInfoLabel, playRow,
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

    private func segmentedRow(title: String, control: UISegmentedControl) -> UIView {
        let label = UILabel()
        label.text = title
        label.textColor = .label
        label.font = .systemFont(ofSize: 14)

        control.selectedSegmentTintColor = .systemBlue
        control.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)

        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        return stack
    }

    private func refreshUI() {
        switch recordingState {
        case .idle:       statusLabel.text = "Idle — tap Start to record"
        case .preparing:  statusLabel.text = "Preparing audio pipeline..."
        case .recording:  statusLabel.text = "Recording..."
        case .stopped:    statusLabel.text = "Stopped — candidates ready"
        case .cancelled:  statusLabel.text = "Cancelled"
        }
        startButton.isEnabled = (recordingState != .preparing && recordingState != .recording)
        stopButton.isEnabled = (recordingState == .recording)
        cancelButton.isEnabled = (recordingState == .recording)
        playOriginalButton.isEnabled = (isReadableAudioFile(originalURL) && recordingState != .preparing && recordingState != .recording)
        playDenoisedButton.isEnabled = (isReadableAudioFile(denoisedURL) && recordingState != .preparing && recordingState != .recording)
        playProcessedButton.isEnabled = (isReadableAudioFile(processedURL) && recordingState != .preparing && recordingState != .recording)
        denoiseModelControl.isEnabled = (recordingState != .preparing && recordingState != .recording)
        denoiseSwitch.isEnabled = (recordingState != .preparing && recordingState != .recording)
        voicePresetControl.isEnabled = (recordingState != .preparing && recordingState != .recording)
        voiceChangerSwitch.isEnabled = (recordingState != .preparing && recordingState != .recording)

        originalInfoLabel.text = describe(url: originalURL, label: "original")
        denoisedInfoLabel.text = describe(url: denoisedURL, label: "denoised")
        processedInfoLabel.text = describe(url: processedURL, label: "processed")
    }

    private func describe(url: URL?, label: String) -> String {
        guard let url else { return "\(label): —" }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let duration = recordingState == .stopped ? audioDuration(for: url) : 0
        return String(
            format: "%@: %@\n  size=%dB  duration=%.2fs",
            label, url.lastPathComponent, size, duration
        )
    }

    private func audioDuration(for url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func isReadableAudioFile(_ url: URL?) -> Bool {
        guard recordingState == .stopped, let url else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((attrs[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            return false
        }
        return (try? AVAudioFile(forReading: url)) != nil
    }

    // MARK: - Actions

    @objc private func onStart() {
        cleanupPlayers()
        startTimestamp = CFAbsoluteTimeGetCurrent()
        logDemo("start tapped")
        recordingState = .preparing
        refreshUI()

        // Let UIKit render "Preparing..." before potentially expensive SDK/model setup.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                try self.startRecording()
                self.recordingState = .recording
                self.logDemo("recording state entered")
            } catch {
                self.recordingState = .idle
                self.statusLabel.text = "Start failed: \(error.localizedDescription)"
                self.logDemo("start failed: \(error.localizedDescription)")
            }
            self.refreshUI()
        }
    }

    @objc private func onStop() {
        logDemo("stop tapped")
        finishRecording(deleteFiles: false)
        recordingState = .stopped
        refreshUI()
        logDemo("stopped original=\(describeForLog(url: originalURL)) denoised=\(describeForLog(url: denoisedURL)) processed=\(describeForLog(url: processedURL))")
    }

    @objc private func onCancel() {
        logDemo("cancel tapped")
        finishRecording(deleteFiles: true)
        recordingState = .cancelled
        refreshUI()
    }

    @objc private func onPlayOriginal() {
        originalPlayer = playFile(at: originalURL)
    }

    @objc private func onPlayDenoised() {
        denoisedPlayer = playFile(at: denoisedURL)
    }

    @objc private func onPlayProcessed() {
        processedPlayer = playFile(at: processedURL)
    }

    // MARK: - Recording impl

    private func startRecording() throws {
        logDemo("configure audio session begin")
        try configureAudioSessionForRecording()
        logDemo("configure audio session done")
        resetEngineForCurrentRoute()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-msg-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let originalURL = dir.appendingPathComponent("original-\(stamp).m4a")
        let denoisedURL = dir.appendingPathComponent("denoised-\(stamp).m4a")
        let processedURL = dir.appendingPathComponent("processed-\(stamp).m4a")
        self.originalURL = originalURL
        self.denoisedURL = denoisedURL
        self.processedURL = processedURL

        originalChunks.removeAll(keepingCapacity: true)
        denoisedChunks.removeAll(keepingCapacity: true)
        processedChunks.removeAll(keepingCapacity: true)
        tapFrameCount = 0

        // ONE multi-tap pipeline replaces the prior pair of single-tap
        // instances — denoise inference happens once per chunk and fans out
        // to whichever taps consume the denoised PCM.
        let voiceChangerEnabled = voiceChangerSwitch.isOn && selectedVoicePitch() != nil
        let processedSoundTouch = SoundTouchConfig(
            enabled: voiceChangerEnabled,
            pitchSemiTones: selectedVoicePitch() ?? 0
        )
        logDemo("pipeline init begin model=\(selectedDenoiseModule()) voicePitch=\(String(describing: selectedVoicePitch()))")
        let pipeline = OfflineAudioPipeline(
            taps: [
                (id: denoisedTapId,  config: PipelineTapConfig(denoise: denoiseSwitch.isOn)),
                (id: processedTapId, config: PipelineTapConfig(
                    denoise: denoiseSwitch.isOn,
                    soundTouch: processedSoundTouch
                )),
            ],
            initialModule: selectedDenoiseModule()
        )
        self.pipeline = pipeline
        logDemo("pipeline init done (multi-tap, ids=\(pipeline.tapIds))")

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputToProcessingConverter = AVAudioConverter(from: inputFormat, to: processingFormat)
        logDemo("input format sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) route=\(routeDescription())")

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        logDemo("engine start begin")
        try engine.start()
        logDemo("engine start done")
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let pipeline = pipeline,
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
        tapFrameCount += Int(monoBuffer.frameLength)

        guard let chPtr = monoBuffer.floatChannelData?[0] else { return }
        let inputArray = Array(UnsafeBufferPointer(start: chPtr, count: Int(monoBuffer.frameLength)))

        // Raw passthrough never touches the SDK. Encoding deferred to Stop.
        originalChunks.append(inputArray)

        // Single multi-tap call → both denoised and denoised+pitch outputs in
        // one shared denoise inference pass.
        let outs = pipeline.processTaps(inputArray)
        if let d = outs[denoisedTapId], !d.isEmpty {
            denoisedChunks.append(d)
        }
        if let p = outs[processedTapId], !p.isEmpty {
            processedChunks.append(p)
        }
    }

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private func writeChunks(_ chunks: [[Float]], to url: URL) throws {
        logDemo("write begin file=\(url.lastPathComponent) chunks=\(chunks.count) samples=\(chunks.reduce(0) { $0 + $1.count })")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: writerFormatSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            for chunk in chunks where !chunk.isEmpty {
                if let buffer = makeBuffer(from: chunk) {
                    try file.write(from: buffer)
                }
            }
        }
        logDemo("write done file=\(url.lastPathComponent) \(describeForLog(url: url))")
    }

    private func finishRecording(deleteFiles: Bool) {
        logDemo("finish begin deleteFiles=\(deleteFiles) frames=\(tapFrameCount) originalChunks=\(originalChunks.count) denoisedChunks=\(denoisedChunks.count) processedChunks=\(processedChunks.count)")
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine.reset()

        if !deleteFiles, let pipeline = pipeline {
            logDemo("flush begin")
            let tails = pipeline.flushTaps()
            let denoisedTail  = tails[denoisedTapId]  ?? []
            let processedTail = tails[processedTapId] ?? []
            logDemo("flushTaps done denoisedTail=\(denoisedTail.count) processedTail=\(processedTail.count)")
            if !denoisedTail.isEmpty  { denoisedChunks.append(denoisedTail) }
            if !processedTail.isEmpty { processedChunks.append(processedTail) }
            do {
                if let originalURL { try writeChunks(originalChunks, to: originalURL) }
                if let denoisedURL { try writeChunks(denoisedChunks, to: denoisedURL) }
                if let processedURL { try writeChunks(processedChunks, to: processedURL) }
            } catch {
                statusLabel.text = "Write failed: \(error.localizedDescription)"
                if let url = originalURL { try? FileManager.default.removeItem(at: url) }
                if let url = denoisedURL { try? FileManager.default.removeItem(at: url) }
                if let url = processedURL { try? FileManager.default.removeItem(at: url) }
                originalURL = nil
                denoisedURL = nil
                processedURL = nil
            }
        }
        logDemo("finish end")

        pipeline?.release()
        pipeline = nil
        inputToProcessingConverter = nil
        originalChunks.removeAll(keepingCapacity: true)
        denoisedChunks.removeAll(keepingCapacity: true)
        processedChunks.removeAll(keepingCapacity: true)

        if deleteFiles {
            if let url = originalURL { try? FileManager.default.removeItem(at: url) }
            if let url = denoisedURL { try? FileManager.default.removeItem(at: url) }
            if let url = processedURL { try? FileManager.default.removeItem(at: url) }
            originalURL = nil
            denoisedURL = nil
            processedURL = nil
        } else {
            try? configureAudioSessionForPlayback()
        }
    }

    private func selectedDenoiseModule() -> AudioModule {
        denoiseModelControl.selectedSegmentIndex == 1 ? .deepfilternet : .rnnoise
    }

    private func selectedVoicePitch() -> Float? {
        let index = voicePresetControl.selectedSegmentIndex
        guard voicePresetPitchValues.indices.contains(index) else { return nil }
        return voicePresetPitchValues[index]
    }

    private func playFile(at url: URL?) -> AVPlayer? {
        guard let url else { return nil }
        logDemo("play tapped file=\(url.lastPathComponent) \(describeForLog(url: url))")
        guard isReadableAudioFile(url) else {
            statusLabel.text = "File is not ready for playback"
            logDemo("play blocked: file not readable")
            return nil
        }
        cleanupPlayers()
        do {
            try configureAudioSessionForPlayback()
            let p = AVPlayer(url: url)
            p.play()
            return p
        } catch {
            statusLabel.text = "Play failed: \(error.localizedDescription)"
            logDemo("play failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func cleanupPlayers() {
        originalPlayer?.pause()
        denoisedPlayer?.pause()
        processedPlayer?.pause()
        originalPlayer = nil
        denoisedPlayer = nil
        processedPlayer = nil
    }

    private func configureAudioSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .record
        )
        try session.setActive(true)
    }

    private func configureAudioSessionForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: []
        )
        try session.setActive(true)
    }

    private func resetEngineForCurrentRoute() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        engine = AVAudioEngine()
    }

    private func routeDescription() -> String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "sessionSampleRate=\(session.sampleRate) inputs=[\(inputs)] outputs=[\(outputs)]"
    }

    private func logDemo(_ message: String) {
        let elapsed = startTimestamp > 0 ? (CFAbsoluteTimeGetCurrent() - startTimestamp) : 0
        print(String(format: "VoiceMsgDemo[%.3fs] %@", elapsed, message))
    }

    private func describeForLog(url: URL?) -> String {
        guard let url else { return "url=nil" }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let duration = audioDuration(for: url)
        let readable = (try? AVAudioFile(forReading: url)) != nil
        return "file=\(url.lastPathComponent) size=\(size) duration=\(String(format: "%.2f", duration)) readable=\(readable)"
    }
}
