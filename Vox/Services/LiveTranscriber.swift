import Speech
import AVFoundation
import Accelerate

/// Streaming speech-to-text using SpeechAnalyzer (macOS 26+).
/// Two modes:
/// - Subtitles: DictationTranscriber — pretty output with punctuation for display
/// - Translation: SpeechTranscriber — optimized for transcription accuracy
/// Preprocesses audio (band-pass filter + pre-emphasis + speech gate + RMS normalization).
final class LiveTranscriber: @unchecked Sendable {

    // MARK: - State (protected by lock)

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var dictationTranscriber: DictationTranscriber?
    private var speechTranscriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var _targetFormat: AVAudioFormat?
    private var _isRunning = false

    // Cached converter — created once, reused for every buffer
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?

    // High-pass filter state (Butterworth 2nd order, 80 Hz cutoff)
    private var hpX1: Float = 0, hpX2: Float = 0
    private var hpY1: Float = 0, hpY2: Float = 0
    private var hpB0: Float = 0, hpB1: Float = 0, hpB2: Float = 0
    private var hpA1: Float = 0, hpA2: Float = 0
    private var hpConfiguredRate: Double = 0

    // Low-pass filter state (Butterworth 2nd order, 8 kHz cutoff)
    private var lpX1: Float = 0, lpX2: Float = 0
    private var lpY1: Float = 0, lpY2: Float = 0
    private var lpB0: Float = 0, lpB1: Float = 0, lpB2: Float = 0
    private var lpA1: Float = 0, lpA2: Float = 0
    private var lpConfiguredRate: Double = 0

    // Pre-emphasis state
    private var preEmphPrev: Float = 0

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

    /// Start transcription.
    /// - `forTranslation: false` — DictationTranscriber (pretty subtitles with punctuation)
    /// - `forTranslation: true` — SpeechTranscriber (accuracy-optimized for translation input)
    @MainActor
    func start(locale: Locale = Locale(identifier: "en-US"), forTranslation: Bool = false) async {
        guard !isRunning else { return }

        var module: any SpeechModule
        var useSpeechTranscriber = forTranslation

        // Try SpeechTranscriber first (better accuracy), fall back to DictationTranscriber if unavailable
        if useSpeechTranscriber {
            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .progressiveTranscription
            )
            module = transcriber

            lock.lock()
            self.speechTranscriber = transcriber
            lock.unlock()
        } else {
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            module = transcriber

            lock.lock()
            self.dictationTranscriber = transcriber
            lock.unlock()
        }

        // Get the audio format — if SpeechTranscriber fails (model not installed), fall back
        var bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])

        if bestFormat == nil && useSpeechTranscriber {
            print("[LiveTranscriber] SpeechTranscriber unavailable for \(locale.identifier), falling back to DictationTranscriber")
            useSpeechTranscriber = false

            lock.lock()
            self.speechTranscriber = nil
            lock.unlock()

            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            module = transcriber

            lock.lock()
            self.dictationTranscriber = transcriber
            lock.unlock()

            bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        }

        guard let bestFormat else {
            print("[LiveTranscriber] Could not get compatible audio format for \(locale.identifier)")
            return
        }

        let speechAnalyzer = SpeechAnalyzer(modules: [module])

        // Create input stream
        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        lock.lock()
        self.analyzer = speechAnalyzer
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
        if useSpeechTranscriber {
            let transcriber = self.speechTranscriber!
            resultsTask = Task.detached { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.isRunning else { break }
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let isFinal = result.isFinal
                            await MainActor.run { callback?(text, isFinal) }
                        }
                    }
                } catch {
                    print("[LiveTranscriber] Results stream error: \(error)")
                }
            }
        } else {
            let transcriber = self.dictationTranscriber!
            resultsTask = Task.detached { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.isRunning else { break }
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let isFinal = result.isFinal
                            await MainActor.run { callback?(text, isFinal) }
                        }
                    }
                } catch {
                    print("[LiveTranscriber] Results stream error: \(error)")
                }
            }
        }

        let moduleName = useSpeechTranscriber ? "SpeechTranscriber" : "DictationTranscriber"
        print("[LiveTranscriber] Started — \(moduleName), locale: \(locale.identifier), format: \(bestFormat)")
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
            preprocessAudio(buffer)
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
            preprocessAudio(outputBuffer)
            continuation.yield(AnalyzerInput(buffer: outputBuffer))
        }
    }

    /// Feed vocabulary hints back to the recognizer to bias it toward known words.
    /// Best-effort — errors are silently ignored.
    func updateVocabulary(_ words: [String]) {
        lock.lock()
        let currentAnalyzer = analyzer
        lock.unlock()

        guard let currentAnalyzer else { return }

        Task {
            let context = AnalysisContext()
            context.contextualStrings[.general] = words
            try? await currentAnalyzer.setContext(context)
            print("[Vocabulary] Updated with \(words.count) words")
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
        speechTranscriber = nil
        _targetFormat = nil
        cachedConverter = nil
        cachedSourceFormat = nil
        hpX1 = 0; hpX2 = 0; hpY1 = 0; hpY2 = 0
        hpConfiguredRate = 0
        lpX1 = 0; lpX2 = 0; lpY1 = 0; lpY2 = 0
        lpConfiguredRate = 0
        preEmphPrev = 0
        lock.unlock()

        task?.cancel()
        print("[LiveTranscriber] Stopped")
    }

    // MARK: - Audio Preprocessing

    /// Band-pass filter + pre-emphasis + noise gate + RMS normalization
    /// to improve speech recognition quality.
    private func preprocessAudio(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let samples = channelData[0]
        applyHighPassFilter(samples, count: count, sampleRate: buffer.format.sampleRate)
        applyLowPassFilter(samples, count: count, sampleRate: buffer.format.sampleRate)
        applyPreEmphasis(samples, count: count)
        guard passesSpeechGate(samples, count: count) else { return }
        applyRMSNormalization(samples, count: count)
    }

    /// Butterworth 2nd-order high-pass at 80 Hz — removes sub-bass (kick drums, 808s)
    /// that carries no speech information but interferes with recognition.
    private func applyHighPassFilter(_ samples: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        if sampleRate != hpConfiguredRate {
            let omega = 2.0 * .pi * 80.0 / sampleRate
            let cosW = cos(omega)
            let alpha = sin(omega) / sqrt(2.0) // Q = 1/√2 (Butterworth)
            let a0 = 1.0 + alpha

            hpB0 = Float((1.0 + cosW) / 2.0 / a0)
            hpB1 = Float(-(1.0 + cosW) / a0)
            hpB2 = Float((1.0 + cosW) / 2.0 / a0)
            hpA1 = Float(-2.0 * cosW / a0)
            hpA2 = Float((1.0 - alpha) / a0)
            hpConfiguredRate = sampleRate
            hpX1 = 0; hpX2 = 0; hpY1 = 0; hpY2 = 0
        }

        for i in 0..<count {
            let x = samples[i]
            let y = hpB0 * x + hpB1 * hpX1 + hpB2 * hpX2 - hpA1 * hpY1 - hpA2 * hpY2
            hpX2 = hpX1; hpX1 = x
            hpY2 = hpY1; hpY1 = y
            samples[i] = y
        }
    }

    /// Butterworth 2nd-order low-pass at 8 kHz — removes high-frequency noise (cymbals, hiss, artifacts)
    /// that carries no speech information but can confuse the recognizer.
    private func applyLowPassFilter(_ samples: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        if sampleRate != lpConfiguredRate {
            let omega = 2.0 * .pi * 8000.0 / sampleRate
            let cosW = cos(omega)
            let alpha = sin(omega) / sqrt(2.0) // Q = 1/√2 (Butterworth)
            let a0 = 1.0 + alpha

            lpB0 = Float((1.0 - cosW) / 2.0 / a0)
            lpB1 = Float((1.0 - cosW) / a0)
            lpB2 = Float((1.0 - cosW) / 2.0 / a0)
            lpA1 = Float(-2.0 * cosW / a0)
            lpA2 = Float((1.0 - alpha) / a0)
            lpConfiguredRate = sampleRate
            lpX1 = 0; lpX2 = 0; lpY1 = 0; lpY2 = 0
        }

        for i in 0..<count {
            let x = samples[i]
            let y = lpB0 * x + lpB1 * lpX1 + lpB2 * lpX2 - lpA1 * lpY1 - lpA2 * lpY2
            lpX2 = lpX1; lpX1 = x
            lpY2 = lpY1; lpY1 = y
            samples[i] = y
        }
    }

    /// Pre-emphasis filter — boosts consonant frequencies (1-4 kHz) that help the recognizer
    /// distinguish similar-sounding words ("forcing" vs "four sing", "space" vs "face").
    /// Standard speech processing: y[n] = x[n] - 0.97 * x[n-1]
    private func applyPreEmphasis(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        let coeff: Float = 0.97
        for i in 0..<count {
            let x = samples[i]
            samples[i] = x - coeff * preEmphPrev
            preEmphPrev = x
        }
    }

    /// Speech gate — checks if the buffer contains enough energy to be speech.
    /// Prevents the RMS normalizer from amplifying silence/music-only segments,
    /// which causes the recognizer to hallucinate words from noise.
    private func passesSpeechGate(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        // After band-pass + pre-emphasis, speech typically has RMS > 0.005.
        // Below that it's background noise or very quiet music.
        return rms > 0.005
    }

    /// Normalizes RMS to ~0.1 so quiet speech and loud music hit the recognizer at consistent levels.
    private func applyRMSNormalization(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))

        guard rms > 1e-6 else { return } // silence — don't amplify noise floor

        let targetRMS: Float = 0.1
        var gain = min(targetRMS / rms, 10.0) // cap at +20 dB

        vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(count))

        // Hard clip to [-1, 1] to prevent distortion
        var lo: Float = -1.0, hi: Float = 1.0
        vDSP_vclip(samples, 1, &lo, &hi, samples, 1, vDSP_Length(count))
    }
}
