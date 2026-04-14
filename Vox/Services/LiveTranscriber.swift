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
    /// Long-lived context mutated and re-applied via setContext() on vocabulary updates.
    private var analysisContext: AnalysisContext?
    /// Locale currently reserved via AssetInventory.reserve(locale:). macOS 26+
    /// requires this before using a speech module — unreserved locales trigger
    /// "Cannot use modules with unallocated locales" warnings.
    private var reservedLocale: Locale?
    /// Set to true once the transcriber delivers its first real result, meaning
    /// the EAR worker has compiled its JIT profile and is ready to accept
    /// contextualStrings updates. Before this, setContext calls hit "Invalid JIT
    /// profile" and get silently rejected.
    private var isWorkerReady = false
    /// Vocabulary buffered while the worker wasn't ready yet — flushed on first result.
    private var pendingVocabulary: [String]?

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

    /// Called when speech pause is detected. Parameter: duration in milliseconds.
    nonisolated(unsafe) var onSilence: ((_ durationMs: Int) -> Void)?

    // Silence tracking
    private var silenceStartTime: TimeInterval = 0
    private var isSilent: Bool = false
    private var silenceFired: Bool = false  // prevent re-firing until speech resumes

    /// Cinema mode: tighter bandpass + higher speech gate for noisy content (series, movies).
    /// Reads/writes go through the shared lock so toggling mid-session can't race with
    /// audio processing (which reads `_cinemaMode` directly while already holding the lock).
    private var _cinemaMode: Bool = false
    var cinemaMode: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cinemaMode }
        set { lock.lock(); defer { lock.unlock() }; _cinemaMode = newValue }
    }

    // MARK: - Public API

    /// Start transcription.
    /// - `forTranslation: false` — DictationTranscriber (pretty subtitles with punctuation)
    /// - `forTranslation: true` — SpeechTranscriber (accuracy-optimized for translation input)
    @MainActor
    func start(locale: Locale = Locale(identifier: "en-US"), forTranslation: Bool = false) async {
        guard !isRunning else { return }

        // macOS 26+ requires locales to be reserved via AssetInventory before a
        // speech module is used on them. Without this, Apple logs "Cannot use
        // modules with unallocated locales" and the EAR worker may reject
        // contextualStrings with "Invalid JIT profile".
        do {
            let reserved = try await AssetInventory.reserve(locale: locale)
            if reserved {
                self.reservedLocale = locale
                print("[LiveTranscriber] Reserved locale: \(locale.identifier)")
            } else {
                print("[LiveTranscriber] AssetInventory.reserve returned false for \(locale.identifier) — proceeding anyway")
            }
        } catch {
            print("[LiveTranscriber] AssetInventory.reserve failed for \(locale.identifier): \(error)")
        }

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
            // Cinema mode: enable .farField — signals that audio is distant-speaker (movie
            // soundtrack played through laptop speakers, not a close mic). Apple's internal
            // processing adapts accordingly.
            let hints: Set<DictationTranscriber.ContentHint> = cinemaMode ? [.farField] : []
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: hints,
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

            let hints: Set<DictationTranscriber.ContentHint> = cinemaMode ? [.farField] : []
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: hints,
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

        // Create input stream
        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Long-lived AnalysisContext — kept around so runtime updateVocabulary
        // calls mutate the same instance and just re-apply it via setContext.
        let context = AnalysisContext()

        let speechAnalyzer = SpeechAnalyzer(modules: [module])

        // Warm up — loads models, allocates resources. Does NOT build the JIT
        // profile for inference; that happens lazily when real audio flows.
        do {
            try await speechAnalyzer.prepareToAnalyze(in: bestFormat)
        } catch {
            print("[LiveTranscriber] prepareToAnalyze failed: \(error)")
        }

        lock.lock()
        self.analyzer = speechAnalyzer
        self.analysisContext = context
        self.inputContinuation = continuation
        self._targetFormat = bestFormat
        self._isRunning = true
        self.isWorkerReady = false
        self.pendingVocabulary = nil
        self.cachedConverter = nil
        self.cachedSourceFormat = nil
        lock.unlock()

        // Start analysis. We intentionally don't push setContext here — the JIT
        // profile inside the EAR worker is only built once audio actually flows,
        // and setContext calls before that get rejected as "Invalid JIT profile".
        // The result consumer below flushes any pending vocabulary on first result.
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
                            self.markWorkerReadyAndFlushPending()
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
                            self.markWorkerReadyAndFlushPending()
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

        // Fast path: format matches, no conversion needed.
        // preprocessAudio mutates filter/silence state — must run under the lock.
        // onSilence is fired AFTER releasing the lock (never invoke user closures under a lock).
        if buffer.format == targetFormat {
            let silenceMs = preprocessAudio(buffer)
            lock.unlock()
            if let silenceMs { onSilence?(silenceMs) }
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
            lock.lock()
            // Re-check: stop() or stop()+start() could have run while the lock was
            // released for conversion. _isRunning covers stop; _targetFormat == targetFormat
            // covers stop+start with a different format (AVAudioFormat == is value equality).
            guard _isRunning, _targetFormat == targetFormat else {
                lock.unlock()
                return
            }
            let silenceMs = preprocessAudio(outputBuffer)
            lock.unlock()
            if let silenceMs { onSilence?(silenceMs) }
            continuation.yield(AnalyzerInput(buffer: outputBuffer))
        }
    }

    /// Feed vocabulary hints back to the recognizer to bias it toward known words.
    /// If the EAR worker hasn't built its JIT profile yet (no audio processed),
    /// buffers the words and flushes them on the first transcriber result.
    func updateVocabulary(_ words: [String]) {
        lock.lock()
        let currentAnalyzer = analyzer
        let context = analysisContext
        let workerReady = isWorkerReady
        if !workerReady {
            self.pendingVocabulary = words
        }
        lock.unlock()

        guard let currentAnalyzer, let context else { return }

        if !workerReady {
            print("[Vocabulary] Deferred \(words.count) words until worker is ready")
            return
        }

        context.contextualStrings[.general] = words

        Task {
            do {
                try await currentAnalyzer.setContext(context)
                print("[Vocabulary] Updated with \(words.count) words: \(words)")
            } catch {
                print("[Vocabulary] setContext FAILED: \(error)")
            }
        }
    }

    /// Called from the result consumer on the first non-empty transcription.
    /// Marks the EAR worker as ready (JIT profile now exists) and applies any
    /// vocabulary that was buffered while the worker was still warming up.
    private func markWorkerReadyAndFlushPending() {
        lock.lock()
        let wasReady = isWorkerReady
        isWorkerReady = true
        let pending = pendingVocabulary
        pendingVocabulary = nil
        let currentAnalyzer = analyzer
        let context = analysisContext
        lock.unlock()

        if wasReady { return }

        guard let pending, let currentAnalyzer, let context else { return }

        context.contextualStrings[.general] = pending

        Task {
            do {
                try await currentAnalyzer.setContext(context)
                print("[Vocabulary] Flushed \(pending.count) pending words on first result: \(pending)")
            } catch {
                print("[Vocabulary] Pending setContext FAILED: \(error)")
            }
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
        analysisContext = nil
        isWorkerReady = false
        pendingVocabulary = nil
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
        silenceStartTime = 0
        isSilent = false
        silenceFired = false
        let localeToRelease = reservedLocale
        reservedLocale = nil
        lock.unlock()

        task?.cancel()

        // Release the reserved locale so we don't blow past maximumReservedLocales
        // on subsequent starts. Fire-and-forget — stop() is @MainActor sync.
        if let localeToRelease {
            Task.detached {
                let released = await AssetInventory.release(reservedLocale: localeToRelease)
                print("[LiveTranscriber] Released locale: \(localeToRelease.identifier) (released=\(released))")
            }
        }

        print("[LiveTranscriber] Stopped")
    }

    // MARK: - Audio Preprocessing

    /// Band-pass filter + pre-emphasis + noise gate + RMS normalization
    /// to improve speech recognition quality.
    ///
    /// MUST be called with `lock` held — mutates filter coefficients, IIR taps,
    /// pre-emphasis state, and silence tracking. Returns the silence-elapsed
    /// duration (ms) when a silence event should fire; caller invokes `onSilence`
    /// after releasing the lock (never call a user closure under NSLock).
    private func preprocessAudio(_ buffer: AVAudioPCMBuffer) -> Int? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }

        let samples = channelData[0]

        applyHighPassFilter(samples, count: count, sampleRate: buffer.format.sampleRate)
        applyLowPassFilter(samples, count: count, sampleRate: buffer.format.sampleRate)
        applyPreEmphasis(samples, count: count)

        // Compute RMS for speech gate AND silence detection
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))

        let isSpeech = rms > (_cinemaMode ? 0.01 : 0.005)

        if isSpeech {
            // Speech resumed — reset silence tracking
            if isSilent {
                isSilent = false
                silenceFired = false
            }
            applyRMSNormalization(samples, count: count)
            return nil
        } else {
            // Silence detected
            let now = Date().timeIntervalSince1970
            if !isSilent {
                isSilent = true
                silenceStartTime = now
            } else if !silenceFired {
                let elapsed = Int((now - silenceStartTime) * 1000)
                if elapsed >= 700 {
                    silenceFired = true
                    return elapsed
                }
            }
            // Don't normalize silence — original gate behavior: skip normalization.
            return nil
        }
    }

    /// Butterworth 2nd-order high-pass — removes sub-bass that interferes with recognition.
    /// Lecture: 80 Hz (standard). Cinema: 200 Hz (aggressive — cuts explosions, bass music).
    private func applyHighPassFilter(_ samples: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        let cutoff = _cinemaMode ? 200.0 : 80.0
        if sampleRate != hpConfiguredRate {
            let omega = 2.0 * .pi * cutoff / sampleRate
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

    /// Butterworth 2nd-order low-pass — removes high-frequency noise that confuses the recognizer.
    /// Lecture: 8 kHz (standard). Cinema: 5 kHz (aggressive — cuts cymbals, hiss, sound effects).
    private func applyLowPassFilter(_ samples: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        let cutoff = _cinemaMode ? 5000.0 : 8000.0
        if sampleRate != lpConfiguredRate {
            let omega = 2.0 * .pi * cutoff / sampleRate
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
