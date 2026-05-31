import Foundation
import Combine
import AVFoundation
import MediaToolbox
import Accelerate
import UIKit  // CADisplayLink

/// Attaches a real-time audio processing tap to an `AVPlayerItem`'s audio mix and
/// surfaces a normalized "RMS volume" (`0…1`) that any view can subscribe to to
/// drive a real reactive visualization.
///
/// We use `MTAudioProcessingTap` — the only public way to peek at sample buffers
/// going through `AVPlayer` short of replacing it with `AVAudioEngine`. The tap
/// runs on a real-time audio thread, so we keep the work tiny (one RMS pass with
/// Accelerate's `vDSP_meamgv`) and hop the result back to the main actor for the UI.
///
/// Caveats:
/// - Tap does **not** work for HLS streams. walkman serves plain MP3/FLAC URLs,
///   so this is fine for us.
/// - Asset tracks must be loaded before installing the mix. We do that async via
///   `loadTracks(...)` and install once they arrive — if the item has already
///   started playing, setting `audioMix` mid-flight still takes effect.
@MainActor
final class AudioLevelTap: ObservableObject {

    @Published private(set) var level: Float = 0   // 0...1, smoothed

    private var tap: MTAudioProcessingTap?
    /// Updated from the audio thread; main actor reads it via the displayLink.
    private var rawLevel: Float = 0
    private var displayLink: CADisplayLink?

    init() {
        setupTap()
        startDisplayLinkSmoothing()
    }

    deinit {
        // Property access on a different actor would warn; tap finalize will
        // clean itself up when its last retain is dropped.
    }

    func install(on item: AVPlayerItem) {
        guard let tap else { return }
        Task {
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                guard let audioTrack = tracks.first else { return }
                await MainActor.run {
                    let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
                    inputParams.audioTapProcessor = tap
                    let mix = AVMutableAudioMix()
                    mix.inputParameters = [inputParams]
                    item.audioMix = mix
                }
            } catch {
                // Asset failed to load — visualization just stays at 0, no UI impact.
            }
        }
    }

    // MARK: - Tap setup

    private func setupTap() {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { tap, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { _ in },
            prepare: { _, _, _ in },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                var timeRange = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut
                )
                guard status == noErr, numberFramesOut.pointee > 0 else { return }

                // Single-pass RMS across whatever buffers/channels we got.
                let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                var sumOfSquares: Float = 0
                var totalSamples: vDSP_Length = 0
                for buffer in bufferList {
                    guard let data = buffer.mData else { continue }
                    let frames = vDSP_Length(buffer.mDataByteSize / 4)  // assume Float32
                    let samples = data.bindMemory(to: Float.self, capacity: Int(frames))
                    var rms: Float = 0
                    vDSP_rmsqv(samples, 1, &rms, frames)
                    sumOfSquares += rms * rms
                    totalSamples += frames
                }
                let level: Float = totalSamples > 0
                    ? min(1, sqrt(sumOfSquares))  // already RMS, no further normalization needed
                    : 0

                // Push to the Swift side. unowned-from-pointer is safe here as long as
                // we cancel the tap before this object deallocs (we do that via the
                // mix being torn down with the player item).
                let storage = MTAudioProcessingTapGetStorage(tap)
                let me = Unmanaged<AudioLevelTap>.fromOpaque(storage).takeUnretainedValue()
                me.rawLevel = level
            }
        )

        var created: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &created
        )
        if status == noErr {
            self.tap = created
        }
    }

    // MARK: - Smoothing

    /// A 60Hz display link smooths the raw RMS into a "rises fast, decays slow"
    /// envelope — much more musical-looking than the raw jittery values. Equivalent
    /// to a peak meter with attack=fast, release=slow.
    private func startDisplayLinkSmoothing() {
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self),
                                 selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick() {
        // Boost a bit — raw RMS for typical music sits around 0.05–0.2.
        let boosted = min(1, rawLevel * 3.5)
        if boosted > level {
            level = level * 0.5 + boosted * 0.5    // fast attack
        } else {
            level = level * 0.85 + boosted * 0.15  // slow release
        }
    }
}

/// CADisplayLink can't directly target a class with a `weak` reference, so we
/// hop through this tiny proxy that keeps owner weak — avoids retain cycle.
private class DisplayLinkProxy {
    weak var owner: AudioLevelTap?
    init(owner: AudioLevelTap) { self.owner = owner }
    @objc func tick() { Task { @MainActor in owner?.tick() } }
}
