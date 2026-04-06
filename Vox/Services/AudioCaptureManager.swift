import AVFoundation
import ScreenCaptureKit

/// Captures audio from Safari via ScreenCaptureKit and delivers PCM chunks for transcription.
final class AudioCaptureManager: NSObject, @unchecked Sendable {

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case safariNotFound
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .safariNotFound: return "Safari is not running."
            case .noDisplay: return "No display found for audio capture."
            }
        }
    }

    // MARK: - Configuration

    /// Samples per chunk at 16 kHz — 3 seconds of audio.
    private let samplesPerChunk = 48_000
    /// Minimum peak amplitude to consider a chunk as containing speech.
    private let vadThreshold: Float = 0.01

    // MARK: - State

    private var stream: SCStream?
    private var sampleBuffer: [Float] = []
    private let audioQueue = DispatchQueue(label: "com.vox.audiocapture", qos: .userInteractive)

    /// Called on `audioQueue` when a 3-second voiced chunk is ready.
    var onAudioChunk: (([Float]) -> Void)?

    // MARK: - Public API

    func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let safari = content.applications.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
            throw CaptureError.safariNotFound
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Display-level filter that includes only Safari's audio.
        let filter = SCContentFilter(display: display, including: [safari], exceptingWindows: [])

        let config = SCStreamConfiguration()
        // Audio settings
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1

        // Dummy video output — ScreenCaptureKit requires at least one
        // screen output, otherwise it returns error -3805.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)

        try await stream.startCapture()
        self.stream = stream
    }

    func stopCapture() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            // Best-effort stop; stream may already be invalid.
        }
        self.stream = nil
        audioQueue.sync {
            sampleBuffer.removeAll()
        }
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let samples = extractPCMSamples(from: sampleBuffer)
        guard !samples.isEmpty else { return }

        self.sampleBuffer.append(contentsOf: samples)

        while self.sampleBuffer.count >= samplesPerChunk {
            let chunk = Array(self.sampleBuffer.prefix(samplesPerChunk))
            self.sampleBuffer.removeFirst(samplesPerChunk)

            // Voice Activity Detection: skip silence.
            let peak = chunk.lazy.map { abs($0) }.max() ?? 0
            guard peak >= vadThreshold else { continue }

            onAudioChunk?(chunk)
        }
    }

    // MARK: - PCM Extraction

    private func extractPCMSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return [] }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else { return [] }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return [] }

        let channelCount = Int(asbd.mChannelsPerFrame)

        // Allocate AudioBufferList for the sample data.
        let audioBufferListSize = AudioBufferList.sizeInBytes(maximumBuffers: channelCount)
        let audioBufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { audioBufferListPointer.deallocate() }

        // Zero-initialize and set buffer count.
        audioBufferListPointer.pointee = AudioBufferList(mNumberBuffers: UInt32(channelCount),
                                                          mBuffers: AudioBuffer(mNumberChannels: 0,
                                                                                mDataByteSize: 0,
                                                                                mData: nil))

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return [] }

        let audioBufferList = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        guard let firstBuffer = audioBufferList.first,
              let data = firstBuffer.mData else { return [] }

        let floatCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let floatPointer = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
    }
}
