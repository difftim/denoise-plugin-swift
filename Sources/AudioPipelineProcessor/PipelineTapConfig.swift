import Foundation

/// Per-tap configuration for the multi-tap mode of ``OfflineAudioPipeline``.
///
/// One ``PipelineTapConfig`` = one output buffer produced from the same shared
/// denoise inference. Each tap independently decides:
///
/// * whether to consume the denoised PCM or fall through with the raw input
///   (``denoise``), and
/// * whether to run its own pitch-shifted SoundTouch chain
///   (``soundTouch``); pass `nil` (or a config with ``SoundTouchConfig/enabled``
///   set to `false`) to skip pitch shifting on this tap.
///
/// Denoise inference runs at most once per input chunk regardless of how many
/// taps consume the denoised PCM. Each tap with SoundTouch has its own
/// stateful pitch shifter so per-tap presets don't interfere.
///
/// Matches the Kotlin `PipelineTapConfig` and the TypeScript
/// `PipelineTapConfig` interface exactly so cross-platform recipes can share
/// the same tap-ID layout.
public struct PipelineTapConfig: Sendable, Equatable {
    /// `true` → this tap consumes the shared denoised frame; `false` → raw mic
    /// passthrough on this tap (SoundTouch still applies if configured).
    public let denoise: Bool

    /// Optional per-tap voice changer. `nil` (or `.enabled == false`) skips
    /// SoundTouch on this tap. Each tap gets an independent stateful chain.
    public let soundTouch: SoundTouchConfig?

    public init(denoise: Bool = false, soundTouch: SoundTouchConfig? = nil) {
        self.denoise = denoise
        self.soundTouch = soundTouch
    }
}
