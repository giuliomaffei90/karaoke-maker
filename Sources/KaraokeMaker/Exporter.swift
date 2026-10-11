import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

enum ExportKind: String, CaseIterable, Identifiable {
    /// Lyrics only on a transparent background, to lay over the video in an editor.
    case overlay
    /// The media with the lyrics burnt in.
    case video

    var id: Self { self }
    var title: String { self == .overlay ? tr("Transparent Overlay") : tr("Video with Lyrics") }
    var detail: String {
        self == .overlay ? tr("ProRes 4444 with alpha, in a .mov, for Final Cut, Premiere or DaVinci Resolve.")
            : tr("H.264 .mp4, ready to play.")
    }
    var fileType: AVFileType { self == .overlay ? .mov : .mp4 }
    var contentType: UTType { self == .overlay ? .quickTimeMovie : .mpeg4Movie }
}

enum Exporter {
    /// Renders the lyrics frame by frame. With a video track, the output has its size and frame rate;
    /// audio-only media get `height` at 30 fps on the style's background colour. The audio is always included.
    static func export(media: URL, lines: [Line], style: KaraokeStyle, kind: ExportKind, height: Int,
                       to url: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: media)
        let duration = try await asset.load(.duration).seconds
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        var size = CGSize(width: (height * 16 / 9 + 1) & ~1, height: height)
        var fps = 30.0
        var composition: AVVideoComposition?
        if let videoTrack {
            // Rotated phone videos come out upright: the composition applies the track's transform.
            let c = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
            composition = c
            size = c.renderSize
            fps = Double(try await videoTrack.load(.nominalFrameRate))
            if fps <= 0 { fps = 30 }
        }

        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: kind.fileType)

        var videoSettings: [String: Any] = [AVVideoWidthKey: size.width, AVVideoHeightKey: size.height]
        if kind == .overlay {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        } else {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: size.width * size.height * fps * 0.2]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let pixelFormat: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes:
            pixelFormat.merging([kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height]) { a, _ in a })
        writer.add(videoInput)

        var sourceFrames: AVAssetReaderVideoCompositionOutput?
        if kind == .video, let videoTrack, let composition {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: pixelFormat)
            output.videoComposition = composition
            reader.add(output)
            sourceFrames = output
        }
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: Transcription.pcmSettings)
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ])
            writer.add(input)
            (audioOutput, audioInput) = (output, input)
        }

        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let video: () -> Bool
        if let sourceFrames {
            video = {
                guard let sample = sourceFrames.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else { return false }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                draw(into: buffer) { ctx in KaraokeRenderer.draw(lines, style: style, at: time.seconds, in: ctx, size: size) }
                progress(min(1, time.seconds / duration))
                return adaptor.append(buffer, withPresentationTime: time)
            }
        } else {
            let frames = Int((duration * fps).rounded(.up))
            var n = 0
            video = {
                guard n < frames, let pool = adaptor.pixelBufferPool else { return false }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { return false }
                let time = Double(n) / fps
                draw(into: buffer) { ctx in
                    let frame = CGRect(origin: .zero, size: size)
                    if kind == .overlay {
                        ctx.clear(frame)
                    } else {
                        ctx.setFillColor(style.background.cgColor)
                        ctx.fill(frame)
                    }
                    KaraokeRenderer.draw(lines, style: style, at: time, in: ctx, size: size)
                }
                n += 1
                progress(Double(n) / Double(frames))
                return adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60_000))
            }
        }

        try await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await Transcription.pump(videoInput, video) }
                if let audioOutput, let audioInput {
                    group.addTask {
                        await Transcription.pump(audioInput) { audioOutput.copyNextSampleBuffer().map { audioInput.append($0) } ?? false }
                    }
                }
            }
            try Task.checkCancellation()
            await writer.finishWriting()
            if let error = writer.error ?? reader.error { throw error }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    private static func draw(into buffer: CVPixelBuffer, _ body: (CGContext) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        body(ctx)
    }
}
