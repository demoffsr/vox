import Speech
import AVFoundation

/// Streaming speech-to-text using DictationTranscriber + SpeechAnalyzer (macOS 26+).
/// Uses DictationTranscriber (NOT SpeechTranscriber) — optimized for real-time live captions
/// with frequent word-by-word updates and far-field audio (speakers/video).
final class LiveTranscriber: @unchecked Sendable {

    // MARK: - State (protected by lock)

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var dictationTranscriber: DictationTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var _targetFormat: AVAudioFormat?
    private var _isRunning = false

    // Cached converter — created once, reused for every buffer
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    /// The audio format SpeechAnalyzer wants. Available after `start()`.
    var preferredAudioFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return _targetFormat
    }

    /// Called with (text, isFinal). Volatile = word-by-word. Final = confirmed.
    nonisolated(unsafe) var onSubtitle: ((_ text: String, _ isFinal: Bool) -> Void)?

    // MARK: - Public API

    @MainActor
    func start(locale: Locale = Locale(identifier: "en-US")) async {
        guard !isRunning else { return }

        // DictationTranscriber — real-time dictation engine, NOT batch transcription
        // - .farField: audio from speakers/video, not close microphone
        // - .volatileResults: emit partial results (word by word)
        // - .frequentFinalization: finalize results more often (lower latency)
        // - .punctuation: auto-add punctuation
        let dictTranscriber = DictationTranscriber(
            locale: locale,
            contentHints: [.farField],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )

        // Get the audio format the engine wants
        guard let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [dictTranscriber]
        ) else {
            print("[LiveTranscriber] Could not get compatible audio format")
            return
        }

        let speechAnalyzer = SpeechAnalyzer(modules: [dictTranscriber])

        // Create input stream
        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        lock.lock()
        self.analyzer = speechAnalyzer
        self.dictationTranscriber = dictTranscriber
        self.inputContinuation = continuation
        self._targetFormat = bestFormat
        self._isRunning = true
        self.cachedConverter = nil
        self.cachedSourceFormat = nil
        lock.unlock()

        // Start analysis
        Task.detached {
            do {
                try await speechAnalyzer.start(inputSequence: inputStream)
            } catch {
                print("[LiveTranscriber] Analyzer start error: \(error)")
            }
        }

        // Listen for results — volatile (word-by-word) and final (confirmed)
        let callback = self.onSubtitle
        resultsTask = Task.detached { [weak self] in
            do {
                for try await result in dictTranscriber.results {
                    guard let self, self.isRunning else { break }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let isFinal = result.isFinal
                        await MainActor.run {
                            callback?(text, isFinal)
                        }
                    }
                }
            } catch {
                print("[LiveTranscriber] Results stream error: \(error)")
            }
        }

        print("[LiveTranscriber] Started — DictationTranscriber, locale: \(locale.identifier), format: \(bestFormat)")
    }

    /// Feed audio buffer. Thread-safe. Handles format conversion with cached converter.
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard _isRunning, let continuation = inputContinuation, let targetFormat = _targetFormat else {
            lock.unlock()
            return
        }

        // Fast path: format matches, no conversion needed
        if buffer.format == targetFormat {
            lock.unlock()
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        // Slow path: convert format. Cache the converter for reuse.
        if cachedSourceFormat != buffer.format {
            cachedConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            cachedSourceFormat = buffer.format
            if cachedConverter == nil {
                print("[LiveTranscriber] WARNING: Cannot create converter from \(buffer.format) to \(targetFormat)")
            } else {
                print("[LiveTranscriber] Created converter: \(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch → \(targetFormat.sampleRate)Hz \(targetFormat.channelCount)ch")
            }
        }

        guard let converter = cachedConverter else {
            lock.unlock()
            return
        }
        lock.unlock()

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if error == nil && outputBuffer.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: outputBuffer))
        }
    }

    @MainActor
    func stop() {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        _isRunning = false
        inputContinuation?.finish()
        inputContinuation = nil
        let task = resultsTask
        resultsTask = nil
        analyzer = nil
        dictationTranscriber = nil
        _targetFormat = nil
        cachedConverter = nil
        cachedSourceFormat = nil
        lock.unlock()

        task?.cancel()
        print("[LiveTranscriber] Stopped")
    }
}
