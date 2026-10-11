import AVFoundation
import SwiftUI

@MainActor @Observable
final class PlayerModel {
    let player = AVPlayer()
    private(set) var url: URL?
    private(set) var duration = 0.0
    /// Width ÷ height of the video, nil for audio-only media.
    private(set) var aspect: Double?
    /// Peak level per 1/100 s, 0…1, for the timeline.
    private(set) var waveform: [Float] = []
    /// Updated 20 times a second; the preview reads the player directly for smooth frames.
    var now = 0.0
    var isPlaying = false
    /// The span being looped, nil when not looping.
    private(set) var loopRange: ClosedRange<Double>?
    private var observer: Any?
    private var loopObserver: Any?
    private var scrubbing = false
    private var scrubAnchor = 0.0
    private var scrubEnd: Task<Void, Never>?
    private var seekInFlight = false
    private var pendingSeek: Double?

    var time: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }

    func load(_ url: URL) async {
        guard url != self.url else { return }
        self.url = url
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        duration = (try? await asset.load(.duration).seconds) ?? 0
        aspect = nil
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let s = size.applying(transform)
            aspect = abs(s.width / s.height)
        }
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.now = self.time
                    self.isPlaying = self.player.rate != 0 && !self.scrubbing
                    // Backstop for the boundary observer, which a seek can jump over.
                    if let range = self.loopRange, self.isPlaying, self.now > range.upperBound + 0.3 { self.restartLoop() }
                }
            }
        }
        waveform = (try? await Self.waveform(of: asset)) ?? []
    }

    func toggle() {
        if player.rate == 0 { player.play() } else { player.pause() }
        isPlaying = player.rate != 0
    }

    func seek(_ seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        now = t.seconds
    }

    // MARK: - Loop

    /// Plays `range` over and over (with a short run-up), or stops looping with nil. When only the range
    /// changes during a loop, playback carries on unless the playhead is outside the new range.
    func loop(_ range: ClosedRange<Double>?, restart: Bool) {
        if let loopObserver { player.removeTimeObserver(loopObserver) }
        loopObserver = nil
        loopRange = range
        guard let range else {
            player.pause()
            isPlaying = false
            return
        }
        let end = CMTime(seconds: range.upperBound + 0.1, preferredTimescale: 600)
        loopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.restartLoop()
            }
        }
        if restart || !(range.lowerBound - 0.3...range.upperBound + 0.1).contains(time) { restartLoop() }
    }

    private func restartLoop() {
        guard let range = loopRange else { return }
        seek(range.lowerBound - 0.15)
        player.play()
        isPlaying = true
    }

    // MARK: - Scrub

    /// Moves the playhead to `seconds` and plays a short bit from there, like scrubbing in an audio editor.
    /// When the scrubbing stops, the playhead goes back to the last scrubbed point (or the loop carries on).
    func scrub(to seconds: Double, length: Double = 0.15) {
        scrubbing = true
        scrubAnchor = max(0, seconds)
        smoothSeek(scrubAnchor)
        player.play()
        isPlaying = false
        scrubEnd?.cancel()
        scrubEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            guard let self, !Task.isCancelled else { return }
            self.scrubbing = false
            if self.loopRange != nil {
                self.restartLoop()
            } else {
                self.player.pause()
                self.seek(self.scrubAnchor)
            }
        }
    }

    /// One seek at a time, always to the latest target: scrubbing stays responsive instead of queueing seeks.
    private func smoothSeek(_ seconds: Double) {
        now = seconds
        guard !seekInFlight else { pendingSeek = seconds; return }
        seekInFlight = true
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.smoothSeek(next)
                }
            }
        }
    }

    nonisolated static func waveform(of asset: AVAsset) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var peaks: [Float] = []
        var peak: Int16 = 0, count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let data = try block.dataBytes()
            data.withUnsafeBytes { raw in
                for s in raw.bindMemory(to: Int16.self) {
                    peak = max(peak, s == .min ? .max : abs(s))
                    count += 1
                    if count == 80 {  // 8000 Hz / 100
                        peaks.append(Float(peak) / Float(Int16.max))
                        (peak, count) = (0, 0)
                    }
                }
            }
        }
        return peaks
    }
}

/// The video picture, without AVKit's own controls.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

extension Double {
    /// 1:05.32
    var timecode: String {
        let t = Swift.max(0, self)
        return String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}
