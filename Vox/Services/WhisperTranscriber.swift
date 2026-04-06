import Foundation
#if canImport(SwiftWhisper)
@preconcurrency import SwiftWhisper
#endif

final class WhisperTranscriber: @unchecked Sendable {
    #if canImport(SwiftWhisper)
    nonisolated(unsafe) private var whisper: Whisper?
    #endif

    private let processingQueue = DispatchQueue(label: "com.vox.whisper", qos: .userInitiated)
    nonisolated(unsafe) private var _isBusy = false
    private let busyLock = NSLock()

    nonisolated var isBusy: Bool {
        busyLock.lock()
        defer { busyLock.unlock() }
        return _isBusy
    }

    nonisolated func loadModel() throws {
        guard let modelPath = Bundle.main.path(forResource: "ggml-small.en-q5_1", ofType: "bin") else {
            throw WhisperError.modelNotFound
        }
        #if canImport(SwiftWhisper)
        let modelURL = URL(fileURLWithPath: modelPath)

        let params = WhisperParams(strategy: .greedy)
        params.language = .english          // Force English — no auto-detection
        params.no_context = true            // Each chunk independent (streaming)
        params.single_segment = true        // Faster: one segment per chunk
        params.n_threads = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 8))
        params.suppress_blank = true
        params.suppress_non_speech_tokens = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false

        whisper = Whisper(fromFileURL: modelURL, withParams: params)
        print("[WhisperTranscriber] Model loaded, threads: \(params.n_threads)")
        #else
        print("[WhisperTranscriber] SwiftWhisper not available — add via Xcode SPM")
        #endif
    }

    nonisolated func transcribe(audioFrames: [Float], completion: @escaping (String?) -> Void) {
        #if canImport(SwiftWhisper)
        guard let whisper else {
            completion(nil)
            return
        }

        busyLock.lock()
        guard !_isBusy else {
            busyLock.unlock()
            print("[WhisperTranscriber] Skipping — already busy")
            completion(nil)
            return
        }
        _isBusy = true
        busyLock.unlock()

        let duration = Double(audioFrames.count) / 16000.0
        print("[WhisperTranscriber] Starting transcription of \(audioFrames.count) samples (\(String(format: "%.1f", duration))s)...")

        processingQueue.async { [weak self] in
            let group = DispatchGroup()
            group.enter()

            var resultText: String?

            Task {
                do {
                    let segments = try await whisper.transcribe(audioFrames: audioFrames)
                    resultText = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    print("[WhisperTranscriber] Result: \(resultText ?? "")")
                } catch {
                    print("[WhisperTranscriber] Error: \(error)")
                }
                group.leave()
            }

            let timeout = group.wait(timeout: .now() + 30)
            self?.busyLock.lock()
            self?._isBusy = false
            self?.busyLock.unlock()

            if timeout == .timedOut {
                print("[WhisperTranscriber] TIMEOUT — transcription took too long")
                completion(nil)
            } else {
                completion(resultText)
            }
        }
        #else
        completion(nil)
        #endif
    }

    nonisolated func cancelIfBusy() {
        #if canImport(SwiftWhisper)
        guard let whisper, isBusy else { return }
        Task {
            try? await whisper.cancel()
            print("[WhisperTranscriber] Cancelled ongoing transcription")
        }
        #endif
    }

    enum WhisperError: Error, LocalizedError {
        case modelNotFound
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "Whisper model file not found in bundle"
            case .modelNotLoaded: return "Whisper model not loaded. Call loadModel() first."
            }
        }
    }
}
