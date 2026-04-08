import AVFoundation
import ScreenCaptureKit

/// Captures system-wide audio via ScreenCaptureKit for live transcription.
/// Works in sandboxed apps. Captures audio from ALL applications, not just Safari.
actor SystemAudioCapture {

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case noDisplay
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display found for audio capture."
            case .noAudioFormat: return "Could not determine audio format."
            }
        }
    }

    // MARK: - State

    private var stream: SCStream?
    private var outputDelegate = AudioOutputDelegate()

    /// Stream of audio buffers for transcription.
    var audioBuffers: AsyncStream<AVAudioPCMBuffer> {
        outputDelegate.bufferStream
    }

    // MARK: - Public API

    /// Start capturing system-wide audio.
    /// - Parameter audioFormat: Target audio format from SpeechAnalyzer. If nil, captures at system native rate.
    func startCapture(audioFormat: AVAudioFormat? = nil) async throws {
        // Fresh delegate — old one's AsyncStream is finished after stopCapture()
        outputDelegate = AudioOutputDelegate()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Capture ALL system audio — exclude no applications
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true

        // Match SpeechAnalyzer's preferred format — no conversion needed
        if let audioFormat {
            config.sampleRate = Int(audioFormat.sampleRate)
            config.channelCount = Int(audioFormat.channelCount)
            print("[SystemAudioCapture] Using SpeechAnalyzer format: \(Int(audioFormat.sampleRate)) Hz, \(audioFormat.channelCount) ch")
        } else {
            // Fallback: system native rate (usually 48kHz)
            config.sampleRate = 48_000
            config.channelCount = 1
        }

        // Dummy video output — ScreenCaptureKit requires at least one screen output
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let queue = DispatchQueue(label: "com.vox.systemAudioCapture", qos: .userInteractive)
        try stream.addStreamOutput(outputDelegate, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(outputDelegate, type: .screen, sampleHandlerQueue: queue)

        try await stream.startCapture()
        self.stream = stream
        print("[SystemAudioCapture] Started capturing system-wide audio at \(config.sampleRate) Hz")
    }

    /// Stop capturing audio.
    func stopCapture() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        outputDelegate.finish()
        print("[SystemAudioCapture] Stopped")
    }
}

// MARK: - Audio Output Delegate

/// Handles SCStream audio callbacks and publishes AVAudioPCMBuffers via AsyncStream.
private final class AudioOutputDelegate: NSObject, SCStreamOutput, @unchecked Sendable {

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    let bufferStream: AsyncStream<AVAudioPCMBuffer>

    override init() {
        var captured: AsyncStream<AVAudioPCMBuffer>.Continuation!
        bufferStream = AsyncStream { continuation in
            captured = continuation
        }
        super.init()
        self.continuation = captured
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Convert CMSampleBuffer → AVAudioPCMBuffer and forward — no VAD filtering.
        // DictationTranscriber handles silence detection internally.
        guard let pcmBuffer = convertToPCMBuffer(sampleBuffer) else { return }
        guard pcmBuffer.frameLength > 0 else { return }

        continuation?.yield(pcmBuffer)
    }

    // MARK: - Conversion

    private func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy audio data from CMSampleBuffer into AVAudioPCMBuffer
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let audioBufferListSize = AudioBufferList.sizeInBytes(maximumBuffers: channelCount)
        let audioBufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { audioBufferListPointer.deallocate() }

        audioBufferListPointer.pointee = AudioBufferList(
            mNumberBuffers: UInt32(channelCount),
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

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
        guard status == noErr else { return nil }

        let audioBufferList = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        guard let firstBuffer = audioBufferList.first,
              let srcData = firstBuffer.mData else { return nil }

        let byteCount = Int(firstBuffer.mDataByteSize)
        guard let dstData = pcmBuffer.floatChannelData?[0] else { return nil }

        // Check if source is Float32 (most common from ScreenCaptureKit)
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            memcpy(dstData, srcData, byteCount)
        } else {
            // Convert Int16 to Float32
            let int16Ptr = srcData.assumingMemoryBound(to: Int16.self)
            let sampleCount = byteCount / MemoryLayout<Int16>.size
            for i in 0..<sampleCount {
                dstData[i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        return pcmBuffer
    }
}
